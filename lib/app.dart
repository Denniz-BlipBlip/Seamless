import 'dart:async';

import 'package:flutter/material.dart';

import 'features/color_analysis_screen.dart';
import 'features/account_screen.dart';
import 'features/auth_screen.dart';
import 'features/camera_measurement_screen.dart';
import 'features/fashion_news_screen.dart';
import 'features/home_screen.dart';
import 'features/measurements_screen.dart';
import 'features/profile_screen.dart';
import 'features/season_style_screen.dart';
import 'features/shop_screen.dart';
import 'features/welcome_screen.dart';
import 'services/session_store.dart';
import 'services/seamly_api.dart';
import 'theme/seamly_theme.dart';
import 'widgets/seamly_header.dart';

class SeamlyApp extends StatelessWidget {
  const SeamlyApp({
    super.key,
    this.api,
    this.initiallyAuthenticated = false,
    this.sessionStore,
  });

  final SeamlyApi? api;
  final bool initiallyAuthenticated;
  final SessionStore? sessionStore;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Seamly',
      debugShowCheckedModeBanner: false,
      theme: buildSeamlyTheme(),
      home: AuthGate(
        api: api ?? SeamlyApi(),
        initiallyAuthenticated: initiallyAuthenticated,
        sessionStore: sessionStore ?? PreferencesSessionStore(),
      ),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.api,
    required this.sessionStore,
    this.initiallyAuthenticated = false,
  });

  final SeamlyApi api;
  final SessionStore sessionStore;
  final bool initiallyAuthenticated;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late bool _ready = widget.initiallyAuthenticated;
  late bool _authenticated = widget.initiallyAuthenticated;
  late bool _welcomeCompleted = widget.initiallyAuthenticated;
  String? _accountToken;
  double? _referenceHeightCm;
  Map<String, double>? _measurements;
  String? _sizeLabel;
  AccountSession? _account;
  String? _signedOutNotice;
  int _accountRevision = 0;
  Future<void> _storageQueue = Future<void>.value();

  Future<void> _store(Future<void> Function() action) {
    final next = _storageQueue.then((_) => action());
    _storageQueue = next.catchError((Object _) {});
    return next;
  }

  @override
  void initState() {
    super.initState();
    if (!widget.initiallyAuthenticated) {
      _restoreSession();
    }
  }

  Future<void> _restoreSession() async {
    final startupDelay = Future<void>.delayed(const Duration(seconds: 1));
    SessionState session;
    try {
      session = await widget.sessionStore.read();
    } on Exception {
      session = const SessionState.signedOut();
    }
    if (session.authenticated && session.token == null) {
      session = const SessionState.signedOut();
      try {
        await widget.sessionStore.setAuthenticated(false);
      } on Exception {
        // Continue to the sign-in screen if legacy preferences cannot be reset.
      }
    }
    await startupDelay;
    if (!mounted) return;
    setState(() {
      _authenticated = session.authenticated;
      _welcomeCompleted = session.welcomeCompleted;
      _accountToken = session.token;
      _referenceHeightCm = session.heightCm;
      _measurements = session.measurements;
      _sizeLabel = session.sizeLabel;
      if (session.token != null &&
          session.email != null &&
          session.heightCm != null) {
        _account = AccountSession(
          token: session.token!,
          email: session.email!,
          heightCm: session.heightCm!,
          name: session.name,
          avatarBase64: session.avatarBase64,
          measurements: session.measurements,
          sizeLabel: session.sizeLabel,
        );
      }
      _ready = true;
    });
    final token = session.token;
    if (session.authenticated && token != null) {
      unawaited(_refreshAccountProfile(token));
    }
  }

  Future<void> _refreshAccountProfile(String token) async {
    final revision = _accountRevision;
    try {
      final profile = await widget.api.fetchAccountProfile(token: token);
      final account = AccountSession.fromApi({
        'token': token,
        'profile': profile,
      });
      if (!mounted || _accountToken != token || revision != _accountRevision) {
        return;
      }
      await _store(() async {
        if (_accountToken == token && revision == _accountRevision) {
          await widget.sessionStore.saveAccountSession(account);
        }
      });
      if (!mounted || _accountToken != token || revision != _accountRevision) {
        return;
      }
      setState(() {
        _account = account;
        _referenceHeightCm = account.heightCm;
        _measurements = account.measurements;
        _sizeLabel = account.sizeLabel;
      });
    } on Exception {
      // Cached profile data keeps the app usable while the API wakes up.
    }
  }

  Future<void> _authenticate(AccountSession session, bool isNewAccount) async {
    _accountRevision++;
    try {
      await _store(() async {
        await widget.sessionStore.saveAccountSession(session);
        await widget.sessionStore.setWelcomeCompleted(!isNewAccount);
      });
    } on Exception {
      // The user can still enter the app if device storage is unavailable.
    }
    if (!mounted) return;
    setState(() {
      _authenticated = true;
      _signedOutNotice = null;
      _welcomeCompleted = !isNewAccount;
      _accountToken = session.token;
      _account = session;
      _referenceHeightCm = session.heightCm;
      _measurements = session.measurements;
      _sizeLabel = session.sizeLabel;
    });
  }

  Future<void> _completeWelcome() async {
    try {
      await widget.sessionStore.setWelcomeCompleted(true);
    } on Exception {
      // Continue for this session even if the preference cannot be stored.
    }
    if (!mounted) return;
    setState(() => _welcomeCompleted = true);
  }

  Future<void> _updateAccount(AccountSession account) async {
    if (!mounted || account.token != _accountToken) return;
    _accountRevision++;
    setState(() {
      _account = account;
      _referenceHeightCm = account.heightCm;
      _measurements = account.measurements;
      _sizeLabel = account.sizeLabel;
    });
    try {
      await _store(() => widget.sessionStore.saveAccountSession(account));
    } on Exception {
      // The server has saved the authoritative profile; refresh it next launch.
    }
  }

  Future<bool> _logout() async {
    _accountRevision++;
    final token = _accountToken;
    var remoteLogout = token == null;
    try {
      if (token != null) await widget.api.logoutAccount(token: token);
      remoteLogout = true;
    } on Exception {
      // Still let the user leave the account on this device while offline.
    }
    await _store(() => widget.sessionStore.setAuthenticated(false));
    if (!mounted) return remoteLogout;
    setState(() {
      _authenticated = false;
      _signedOutNotice = remoteLogout
          ? null
          : 'Logged out on this device. Server logout could not be confirmed while offline.';
      _welcomeCompleted = false;
      _accountToken = null;
      _account = null;
      _referenceHeightCm = null;
      _measurements = null;
      _sizeLabel = null;
    });
    return remoteLogout;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 420),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: !_ready
          ? const _SessionLoadingScreen(key: ValueKey('session-loading'))
          : !_authenticated
          ? AuthScreen(
              key: const ValueKey('auth-screen'),
              api: widget.api,
              onAuthenticated: _authenticate,
              notice: _signedOutNotice,
            )
          : !_welcomeCompleted
          ? WelcomeScreen(
              key: const ValueKey('welcome-screen'),
              onContinue: _completeWelcome,
            )
          : SeamlyShell(
              key: const ValueKey('app-shell'),
              api: widget.api,
              sessionStore: widget.sessionStore,
              accountToken: _accountToken,
              referenceHeightCm: _referenceHeightCm,
              initialMeasurements: _measurements,
              initialSizeLabel: _sizeLabel,
              account: _account,
              onAccountSaved: _updateAccount,
              onLogout: _logout,
            ),
    );
  }
}

class _SessionLoadingScreen extends StatelessWidget {
  const _SessionLoadingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFF7F0E9),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.72, end: 1),
              duration: const Duration(milliseconds: 1100),
              curve: Curves.easeInOutCubic,
              builder: (context, value, child) => Transform.scale(
                scale: value,
                child: Container(
                  width: 216,
                  height: 216,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7F0E9),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFE88A42).withValues(alpha: 0.35),
                        blurRadius: 44,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: child,
                ),
              ),
              child: Image.asset(
                key: const ValueKey('launch-logo'),
                'assets/images/seamly_logo.png',
                fit: BoxFit.contain,
                semanticLabel: 'Seamly logo',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SeamlyShell extends StatefulWidget {
  const SeamlyShell({
    super.key,
    required this.api,
    required this.sessionStore,
    this.accountToken,
    this.referenceHeightCm,
    this.initialMeasurements,
    this.initialSizeLabel,
    this.account,
    this.onAccountSaved,
    this.onLogout,
  });

  final SeamlyApi api;
  final SessionStore sessionStore;
  final String? accountToken;
  final double? referenceHeightCm;
  final Map<String, double>? initialMeasurements;
  final String? initialSizeLabel;
  final AccountSession? account;
  final Future<void> Function(AccountSession)? onAccountSaved;
  final Future<bool> Function()? onLogout;

  @override
  State<SeamlyShell> createState() => _SeamlyShellState();
}

class _SeamlyShellState extends State<SeamlyShell> {
  int _selectedIndex = 0;
  late String? _sizeLabel = widget.initialSizeLabel;
  String? _colorSeason;
  late Map<String, double>? _scannedMeasurements = widget.initialMeasurements;
  int _scanRevision = 0;

  @override
  void didUpdateWidget(covariant SeamlyShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.referenceHeightCm != widget.referenceHeightCm ||
        oldWidget.initialMeasurements != widget.initialMeasurements ||
        oldWidget.initialSizeLabel != widget.initialSizeLabel) {
      _scanRevision++;
      _scannedMeasurements = widget.initialMeasurements;
      _sizeLabel = widget.initialSizeLabel;
    }
  }

  Future<void> _openAccount() async {
    final account = widget.account;
    if (account == null ||
        widget.onLogout == null ||
        widget.onAccountSaved == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in to manage your account.')),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AccountScreen(
          api: widget.api,
          account: account,
          onSaved: (updated) async {
            _scanRevision++;
            await widget.onAccountSaved!(updated);
            if (!mounted) return;
            setState(() {
              _scannedMeasurements = updated.measurements;
              _sizeLabel = updated.sizeLabel;
            });
          },
          onLogout: () {
            _scanRevision++;
            return widget.onLogout!();
          },
        ),
      ),
    );
  }

  void _selectPage(int index) {
    if (index == _selectedIndex) return;
    setState(() => _selectedIndex = index);
  }

  Future<void> _saveScanMeasurements(Map<String, double> values) async {
    final revision = ++_scanRevision;
    final token = widget.accountToken;
    setState(() => _scannedMeasurements = values);
    var savedSize = _sizeLabel;
    try {
      final result = await widget.api.recommendSize(
        measurements: values,
        fitPreference: 'regular',
      );
      savedSize = result['recommended_size'] as String;
      if (mounted && revision == _scanRevision) {
        setState(() => _sizeLabel = savedSize);
      }
    } on ApiException {
      // The scan remains useful even if the optional size follow-up is offline.
    }
    if (!mounted || revision != _scanRevision) return;
    try {
      if (token != null) {
        await widget.api.saveAccountMeasurements(
          token: token,
          measurements: values,
          sizeLabel: savedSize,
        );
      }
      if (!mounted || revision != _scanRevision) return;
      await widget.sessionStore.saveMeasurementProfile(values, savedSize);
    } on Exception {
      // Keep the accepted measurements on screen if cloud sync is unavailable.
    }
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      HomeScreen(
        api: widget.api,
        showHeader: false,
        onSelectFeature: _selectPage,
        sizeLabel: _sizeLabel,
        colorSeason: _colorSeason,
        measurements: _scannedMeasurements,
        onOpenAccount: _openAccount,
        avatarBase64: widget.account?.avatarBase64,
      ),
      ShopScreen(
        api: widget.api,
        measurements: _scannedMeasurements,
        sizeLabel: _sizeLabel,
        colorSeason: _colorSeason,
        onOpenScanner: () => _selectPage(2),
        onOpenMeasurements: () => _selectPage(5),
      ),
      CameraMeasurementScreen(
        key: ValueKey('scanner-height-${widget.referenceHeightCm}'),
        api: widget.api,
        active: _selectedIndex == 2,
        referenceHeightCm: widget.referenceHeightCm,
        onBack: () => _selectPage(0),
        onMeasurementsReady: _saveScanMeasurements,
        onColorSeasonAnalyzed: (value) => setState(() => _colorSeason = value),
        onOpenShop: () => _selectPage(1),
        onOpenAccount: _openAccount,
        avatarBase64: widget.account?.avatarBase64,
      ),
      FashionNewsScreen(api: widget.api, active: _selectedIndex == 3),
      ProfileScreen(
        api: widget.api,
        showHeader: false,
        avatarBase64: widget.account?.avatarBase64,
        sizeLabel: _sizeLabel,
        colorSeason: _colorSeason,
        onOpenFit: () => _selectPage(2),
        onOpenWeather: () => _selectPage(7),
        onOpenColorAnalysis: () => _selectPage(6),
        onColorSeasonAnalyzed: (value) => setState(() => _colorSeason = value),
        onOpenAccount: _openAccount,
      ),
      MeasurementsScreen(
        key: ValueKey('measurements-height-${widget.referenceHeightCm}'),
        api: widget.api,
        initialMeasurements: _scannedMeasurements,
        onSizeRecommended: (value) => setState(() => _sizeLabel = value),
      ),
      ColorAnalysisScreen(
        api: widget.api,
        onSeasonAnalyzed: (value) => setState(() => _colorSeason = value),
      ),
      SeasonStyleScreen(
        api: widget.api,
        sizeLabel: _sizeLabel,
        colorSeason: _colorSeason,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final content = IndexedStack(
          index: _selectedIndex,
          children: [
            for (var index = 0; index < screens.length; index++)
              if (index == 0 || index == 2)
                screens[index]
              else
                SafeArea(top: false, child: screens[index]),
          ],
        );
        return Scaffold(
          extendBody: false,
          resizeToAvoidBottomInset: true,
          backgroundColor: SeamlyColors.cream,
          body: Row(
            children: [
              if (wide && _selectedIndex != 2)
                _DesktopNavigation(
                  selectedIndex: _selectedIndex,
                  onSelect: _selectPage,
                )
              else
                const SizedBox.shrink(),
              Expanded(
                child: Column(
                  children: [
                    if (_selectedIndex != 2)
                      SeamlyHeader(
                        onOpenAccount: _openAccount,
                        avatarBase64: widget.account?.avatarBase64,
                        onBack: _selectedIndex > 4 ? () => _selectPage(4) : null,
                      ),
                    Expanded(child: content),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: wide || _selectedIndex == 2
              ? null
              : _BottomNavigation(
                  selectedIndex: _selectedIndex,
                  onSelect: _selectPage,
                ),
        );
      },
    );
  }
}

class _BottomNavigation extends StatelessWidget {
  const _BottomNavigation({
    required this.selectedIndex,
    required this.onSelect,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelect;

  static const _destinations = [
    (
      label: 'Home',
      screenIndex: 0,
      icon: Icons.home_outlined,
      selected: Icons.home_rounded,
    ),
    (
      label: 'Shop',
      screenIndex: 1,
      icon: Icons.shopping_cart_outlined,
      selected: Icons.shopping_cart_rounded,
    ),
    (
      label: 'News',
      screenIndex: 3,
      icon: Icons.newspaper_outlined,
      selected: Icons.newspaper_rounded,
    ),
    (
      label: 'Profile',
      screenIndex: 4,
      icon: Icons.person_outline_rounded,
      selected: Icons.person_rounded,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return SizedBox(
      height: 92 + bottomInset,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        alignment: Alignment.topCenter,
        children: [
          Positioned(
            left: 10,
            right: 10,
            bottom: 6 + bottomInset,
            height: 66,
            child: Material(
              color: Colors.white,
              elevation: 10,
              shadowColor: Colors.black26,
              borderRadius: BorderRadius.circular(22),
              clipBehavior: Clip.antiAlias,
              child: Row(
                children: [
                  for (final destination in _destinations.take(2))
                    Expanded(
                      child: _BottomNavigationItem(
                        key: ValueKey('home-nav-${destination.label}'),
                        label: destination.label,
                        icon: selectedIndex == destination.screenIndex
                            ? destination.selected
                            : destination.icon,
                        selected: selectedIndex == destination.screenIndex,
                        onTap: () => onSelect(destination.screenIndex),
                      ),
                    ),
                  const SizedBox(width: 78),
                  for (final destination in _destinations.skip(2))
                    Expanded(
                      child: _BottomNavigationItem(
                        key: ValueKey('home-nav-${destination.label}'),
                        label: destination.label,
                        icon: selectedIndex == destination.screenIndex
                            ? destination.selected
                            : destination.icon,
                        selected: selectedIndex == destination.screenIndex,
                        onTap: () => onSelect(destination.screenIndex),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 2,
            child: Semantics(
              button: true,
              selected: selectedIndex == 2,
              label: 'Scan',
              child: Tooltip(
                message: 'AI body scan',
                child: Material(
                  key: const ValueKey('home-nav-Scan'),
                  color: selectedIndex == 2
                      ? SeamlyColors.sand
                      : Colors.white,
                  elevation: 12,
                  shadowColor: Colors.black38,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onSelect(2),
                    customBorder: const CircleBorder(),
                    child: SizedBox.square(
                      dimension: 80,
                      child: Icon(
                        Icons.photo_camera_rounded,
                        size: 43,
                        color: selectedIndex == 2
                            ? Colors.white
                            : SeamlyColors.ink,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomNavigationItem extends StatelessWidget {
  const _BottomNavigationItem({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(18),
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                width: selected ? 48 : 42,
                height: 44,
                decoration: BoxDecoration(
                  color: selected
                      ? SeamlyColors.sand.withValues(alpha: 0.18)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 220),
                  scale: selected ? 1.08 : 1,
                  child: Icon(
                    icon,
                    size: 30,
                    color: selected
                        ? SeamlyColors.sandText
                        : Colors.black.withValues(alpha: 0.66),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopNavigation extends StatelessWidget {
  const _DesktopNavigation({
    required this.selectedIndex,
    required this.onSelect,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      color: SeamlyColors.ink,
      padding: const EdgeInsets.fromLTRB(18, 28, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: _BrandMark(light: true),
          ),
          const SizedBox(height: 42),
          _NavItem(
            index: 0,
            icon: Icons.home_outlined,
            label: 'Home',
            selectedIndex: selectedIndex,
            onSelect: onSelect,
          ),
          _NavItem(
            index: 1,
            icon: Icons.shopping_cart_outlined,
            label: 'Shop',
            selectedIndex: selectedIndex,
            onSelect: onSelect,
          ),
          _NavItem(
            index: 2,
            icon: Icons.photo_camera_outlined,
            label: 'AI body scan',
            selectedIndex: selectedIndex,
            onSelect: onSelect,
          ),
          _NavItem(
            index: 3,
            icon: Icons.newspaper_outlined,
            label: 'Fashion news',
            selectedIndex: selectedIndex,
            onSelect: onSelect,
          ),
          _NavItem(
            index: 4,
            icon: Icons.person_outline_rounded,
            label: 'Profile',
            selectedIndex: selectedIndex,
            onSelect: onSelect,
          ),
          const Spacer(),
          Text(
            'Your fit. Your style.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.58),
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.index,
    required this.icon,
    required this.label,
    required this.selectedIndex,
    required this.onSelect,
  });

  final int index;
  final IconData icon;
  final String label;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final selected = index == selectedIndex;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? Colors.white.withValues(alpha: 0.13)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: () => onSelect(index),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(icon, color: selected ? Colors.white : Colors.white60),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: selected ? Colors.white : Colors.white70,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.light});

  final bool light;

  @override
  Widget build(BuildContext context) {
    final color = light ? Colors.white : SeamlyColors.ink;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/images/seamly_logo.png',
          width: 58,
          height: 58,
          fit: BoxFit.contain,
          semanticLabel: 'Seamly logo',
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'Fashion',
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
                TextSpan(
                  text: 'Tech',
                  style: TextStyle(
                    color: SeamlyColors.berry,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
