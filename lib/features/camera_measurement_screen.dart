import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/body_profile_extractor.dart';
import '../services/pose_scan_service.dart' show ScanAngle;
import '../services/scan_consent.dart';
import '../services/seamly_api.dart';
import '../theme/seamly_theme.dart';
import '../widgets/common.dart';
import 'guided_scan_screen.dart';
import 'selfie_scan_screen.dart';

/// Builds the body camera step. Tests replace it so no real camera is needed.
typedef ScanViewBuilder =
    Widget Function(
      ValueChanged<Map<ScanAngle, ScanShot>> onCompleted,
      VoidCallback onCancel,
    );

/// Builds the selfie camera step. Tests replace it so no real camera is needed.
/// Completes with sampled color frames, never a photo.
typedef FaceViewBuilder =
    Widget Function(
      ValueChanged<List<Map<String, dynamic>>> onCompleted,
      VoidCallback onCancel,
    );

class CameraMeasurementScreen extends StatefulWidget {
  const CameraMeasurementScreen({
    super.key,
    required this.api,
    required this.active,
    required this.referenceHeightCm,
    required this.onBack,
    required this.onMeasurementsReady,
    required this.onColorSeasonAnalyzed,
    required this.onOpenShop,
    this.consentStore,
    this.onOpenAccount,
    this.avatarBase64,
    this.extractor,
    this.scanBuilder,
    this.faceBuilder,
  });

  final SeamlyApi api;
  final bool active;
  final double? referenceHeightCm;
  final VoidCallback onBack;
  final ValueChanged<Map<String, double>> onMeasurementsReady;
  final ValueChanged<String> onColorSeasonAnalyzed;
  final VoidCallback onOpenShop;

  /// Remembers the one-time scan consent. Defaults to device preferences.
  final ScanConsentStore? consentStore;
  final VoidCallback? onOpenAccount;
  final String? avatarBase64;

  /// Measures the three photos on the phone. Defaults to the real one.
  final BodyProfileExtractor? extractor;

  /// Replaces the guided body camera screen (for tests).
  final ScanViewBuilder? scanBuilder;

  /// Replaces the selfie camera screen (for tests).
  final FaceViewBuilder? faceBuilder;

  @override
  State<CameraMeasurementScreen> createState() =>
      _CameraMeasurementScreenState();
}

enum _ScanStage { prepare, scanning, review }

enum _ScanKind { body, face }

class _CameraMeasurementScreenState extends State<CameraMeasurementScreen> {
  BodyProfileExtractor? _ownedExtractor;
  _ScanStage _stage = _ScanStage.prepare;
  _ScanKind _kind = _ScanKind.body;
  Uint8List? _frontPhoto;
  Map<String, dynamic>? _result;
  Map<String, dynamic>? _colorResult;
  String? _error;
  String? _colorError;
  bool _analyzing = false;
  bool _analyzingColor = false;
  late final ScanConsentStore _consent =
      widget.consentStore ?? PreferencesScanConsentStore();
  int _scanGeneration = 0;

  bool get _busy => _analyzing || _analyzingColor;
  bool _currentScan(int generation) =>
      mounted && widget.active && generation == _scanGeneration;

  BodyProfileExtractor _extractor() =>
      widget.extractor ?? (_ownedExtractor ??= BodyProfileExtractor());

  @override
  void didUpdateWidget(covariant CameraMeasurementScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active && oldWidget.active) {
      // Leaving the tab: drop any scan in progress and start fresh next time.
      _scanGeneration++;
      _stage = _ScanStage.prepare;
      _clearOutcome();
    }
  }

  @override
  void dispose() {
    _scanGeneration++;
    unawaited(_ownedExtractor?.dispose());
    super.dispose();
  }

  void _clearOutcome() {
    _frontPhoto = null;
    _result = null;
    _colorResult = null;
    _error = null;
    _colorError = null;
    _analyzing = false;
    _analyzingColor = false;
  }

  bool get _hasValidCalibration {
    final height = widget.referenceHeightCm;
    return height != null && height >= 120 && height <= 230;
  }

  /// Asks for consent only the first time; the answer is remembered.
  Future<bool> _ensureConsent() async {
    try {
      if (await _consent.isGranted()) return true;
    } on Exception {
      // If the saved answer cannot be read, ask again.
    }
    if (!mounted) return false;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Before your first scan'),
        content: const SingleChildScrollView(
          child: Text(
            'Body scan: your photos are measured on this phone. Only the measurements are sent to Seamly.\n\n'
            'Face colors: your selfie is read on this phone. Only color numbers are sent, never the photo.\n\n'
            'Results are estimates. Check measurements with a soft tape before buying or altering clothes.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            key: const ValueKey('scan-consent-agree'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('I agree'),
          ),
        ],
      ),
    );
    if (agreed != true) return false;
    try {
      await _consent.grant();
    } on Exception {
      // Continue for this session even if the answer cannot be saved.
    }
    return true;
  }

  Future<void> _chooseBody() async {
    if (!_hasValidCalibration) {
      setState(() {
        _error =
            'A verified height is missing from this account. Create or update your profile before scanning.';
      });
      return;
    }
    if (!await _ensureConsent() || !mounted) return;
    _beginScan(_ScanKind.body);
  }

  Future<void> _chooseFace() async {
    if (!await _ensureConsent() || !mounted) return;
    _beginScan(_ScanKind.face);
  }

  void _beginScan(_ScanKind kind) {
    if (kind == _ScanKind.body && !_hasValidCalibration) {
      setState(() {
        _error =
            'A verified height is missing from this account. Create or update your profile before scanning.';
      });
      return;
    }
    setState(() {
      _scanGeneration++;
      _clearOutcome();
      _kind = kind;
      _stage = _ScanStage.scanning;
    });
  }

  void _cancelScan() {
    if (!mounted) return;
    setState(() {
      _scanGeneration++;
      _clearOutcome();
      _stage = _ScanStage.prepare;
    });
  }

  void _retake() {
    if (_busy) return;
    _beginScan(_kind);
  }

  void _reviewInstructions() {
    if (_busy) return;
    _cancelScan();
  }

  Future<void> _onScanCompleted(Map<ScanAngle, ScanShot> shots) async {
    if (!mounted ||
        !widget.active ||
        _stage != _ScanStage.scanning ||
        _kind != _ScanKind.body) {
      return;
    }
    final height = widget.referenceHeightCm;
    if (height == null) return;
    final generation = _scanGeneration;
    final frontBytes = shots[ScanAngle.front]?.jpegBytes;
    setState(() {
      _stage = _ScanStage.review;
      _frontPhoto = frontBytes;
      _result = null;
      _colorResult = null;
      _error = null;
      _colorError = null;
      _analyzing = true;
      _analyzingColor = false;
    });
    try {
      // Measured on the phone: only numbers go to the server.
      final profile = await _extractor().extract(
        shots: shots,
        heightCm: height,
      );
      if (!_currentScan(generation)) return;
      final result = await widget.api.analyzeBodyProfile(profile.toJson());
      if (!_currentScan(generation)) return;
      final measurements = (result['measurements'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, (value as num).toDouble()),
      );
      setState(() => _result = result);
      final confidence =
          (result['measurement_confidence'] as Map<String, dynamic>?) ??
          const <String, dynamic>{};
      final displayable = (result['displayable_measurements'] as List<dynamic>?)
          ?.map((item) => item.toString())
          .toSet();
      final reliableFit = {'chest', 'waist', 'hip'}.every(
        (key) =>
            displayable?.contains(key) ??
            ((confidence[key] as num?)?.toDouble() ?? 0) >= 0.58,
      );
      if (reliableFit) {
        widget.onMeasurementsReady(measurements);
      }
    } on ScanExtractionException catch (error) {
      if (_currentScan(generation)) {
        setState(() => _error = error.message);
      }
    } on ApiException catch (error) {
      if (_currentScan(generation)) {
        setState(() => _error = error.message);
      }
    } on Exception {
      if (_currentScan(generation)) {
        setState(
          () => _error = 'The scan could not be analyzed. Please try again.',
        );
      }
    } finally {
      if (_currentScan(generation)) {
        setState(() {
          _analyzing = false;
          _analyzingColor = false;
        });
      }
    }
  }

  Future<void> _onFaceCompleted(List<Map<String, dynamic>> frames) async {
    if (!mounted ||
        !widget.active ||
        _stage != _ScanStage.scanning ||
        _kind != _ScanKind.face) {
      return;
    }
    final generation = _scanGeneration;
    setState(() {
      _clearOutcome();
      _stage = _ScanStage.review;
      _analyzingColor = true;
    });
    try {
      // Only sampled color numbers go to the server, never the photos.
      final colorResult = await widget.api.analyzeColorFrames(frames);
      if (!_currentScan(generation)) return;
      setState(() => _colorResult = colorResult);
      widget.onColorSeasonAnalyzed(colorResult['color_season'] as String);
    } on ApiException catch (error) {
      if (_currentScan(generation)) {
        setState(() => _colorError = error.message);
      }
    } on Exception {
      if (_currentScan(generation)) {
        setState(
          () => _colorError =
              'The color scan could not be analyzed. Please try again.',
        );
      }
    } finally {
      if (_currentScan(generation)) {
        setState(() {
          _analyzing = false;
          _analyzingColor = false;
        });
      }
    }
  }

  void _showResults() {
    if (_busy) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.85,
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 650),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _kind == _ScanKind.face
                                ? 'Your colors'
                                : 'Your scan',
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close results',
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    if (_frontPhoto != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Image.memory(
                          _frontPhoto!,
                          height: 200,
                          fit: BoxFit.contain,
                          semanticLabel: 'Your front scan photo',
                        ),
                      ),
                    if (_colorResult != null)
                      _CameraColorResult(result: _colorResult!),
                    if (_colorError != null)
                      _ColorAnalysisUnavailable(message: _colorError!),
                    if (_result != null) ...[
                      const SizedBox(height: 16),
                      _MeasurementResults(
                        result: _result!,
                        onOpenShop: () {
                          Navigator.pop(sheetContext);
                          widget.onOpenShop();
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !widget.active,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !widget.active) return;
        if (_stage == _ScanStage.scanning) {
          _cancelScan();
        } else {
          widget.onBack();
        }
      },
      child: switch (_stage) {
        _ScanStage.prepare => _buildPrepare(),
        _ScanStage.scanning => _buildScanning(),
        _ScanStage.review => _buildReview(),
      },
    );
  }

  Widget _buildScanning() {
    if (_kind == _ScanKind.face) {
      return widget.faceBuilder?.call(_onFaceCompleted, _cancelScan) ??
          SelfieScanScreen(
            key: ValueKey('selfie-scan-$_scanGeneration'),
            onCompleted: _onFaceCompleted,
            onCancel: _cancelScan,
          );
    }
    return widget.scanBuilder?.call(_onScanCompleted, _cancelScan) ??
        GuidedScanScreen(
          key: ValueKey('guided-scan-$_scanGeneration'),
          onCompleted: _onScanCompleted,
          onCancel: _cancelScan,
        );
  }

  Widget _buildPrepare() {
    return ColoredBox(
      color: SeamlyColors.cream,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Back home',
                        onPressed: widget.onBack,
                        icon: const Icon(Icons.arrow_back),
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Scan',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _ScanOptionCard(
                    key: const ValueKey('scan-option-body'),
                    icon: Icons.accessibility_new_rounded,
                    title: 'Body scan',
                    subtitle:
                        'Measurements and your size. Three photos, about a minute. Wear fitted clothes and stand 2–3 m away.',
                    onTap: _chooseBody,
                  ),
                  const SizedBox(height: 14),
                  _ScanOptionCard(
                    key: const ValueKey('scan-option-face'),
                    icon: Icons.face_retouching_natural_rounded,
                    title: 'Face colors',
                    subtitle:
                        'Find the colors that suit you. A few seconds in bright, natural light.',
                    onTap: _chooseFace,
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Results are estimates. Check measurements with a soft tape and the seller’s size chart before buying or altering clothing.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11.5, color: Colors.black54),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    ErrorBanner(message: _error!),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReview() {
    final hasOutcome = _result != null || _colorResult != null;
    final isFace = _kind == _ScanKind.face;
    return ColoredBox(
      color: SeamlyColors.cream,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Back home',
                        onPressed: widget.onBack,
                        icon: const Icon(Icons.arrow_back),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isFace ? 'Face colors' : 'Body scan',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_frontPhoto != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Image.memory(
                        _frontPhoto!,
                        width: double.infinity,
                        height: 320,
                        fit: BoxFit.cover,
                        semanticLabel: 'Your front scan photo',
                      ),
                    ),
                  const SizedBox(height: 16),
                  if (_busy)
                    _ScanProgressCard(
                      message: _analyzingColor
                          ? 'Reading your colors…'
                          : 'Measuring your body from the photos…',
                    ),
                  if (_error != null) ErrorBanner(message: _error!),
                  if (_colorError != null && !_busy) ...[
                    const SizedBox(height: 12),
                    _ColorAnalysisUnavailable(message: _colorError!),
                  ],
                  if (!_busy && hasOutcome) ...[
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      key: const ValueKey('camera-view-results'),
                      onPressed: _showResults,
                      icon: const Icon(Icons.keyboard_arrow_up),
                      label: const Text('View results'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                      ),
                    ),
                  ],
                  if (!_busy) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: const ValueKey('scan-again-button'),
                      onPressed: _retake,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Scan again'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('review-instructions-button'),
                      onPressed: _reviewInstructions,
                      child: const Text('Back to scan options'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScanProgressCard extends StatelessWidget {
  const _ScanProgressCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const ValueKey('scan-progress'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            const SizedBox.square(
              dimension: 26,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanOptionCard extends StatelessWidget {
  const _ScanOptionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$title. $subtitle',
      excludeSemantics: true,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: SeamlyColors.sand.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: SeamlyColors.sandText, size: 30),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 13.5,
                          height: 1.35,
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ColorAnalysisUnavailable extends StatelessWidget {
  const _ColorAnalysisUnavailable({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      color: const Color(0xFFFFF4E8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.light_mode_outlined, color: Color(0xFF9A5C18)),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Color analysis needs another scan',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    style: const TextStyle(fontSize: 12.5, height: 1.35),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraColorResult extends StatelessWidget {
  const _CameraColorResult({required this.result});

  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final palette = (result['palette'] as List<dynamic>).cast<String>();
    final metals = (result['metals'] as List<dynamic>).cast<String>();
    final warnings =
        (result['quality_warnings'] as List<dynamic>?)?.cast<String>() ??
        const <String>[];
    final confidence = ((result['confidence'] as num) * 100).round();
    final lighting = (((result['lighting_quality'] as num?) ?? 0) * 100)
        .round();
    final reliable = confidence >= 65 && lighting >= 60;

    return Card(
      key: const ValueKey('camera-color-analysis-result'),
      margin: EdgeInsets.zero,
      color: const Color(0xFFF4EEF5),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.palette_rounded, color: SeamlyColors.plum),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    '${result['color_season']} color direction',
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: reliable
                      ? const Color(0xFFE4F4E8)
                      : const Color(0xFFFFE8C7),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  reliable ? 'Good capture' : 'Retake advised',
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              '${result['complexion_direction']} • $confidence% color confidence • $lighting% lighting quality',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 15),
            Wrap(
              spacing: 9,
              runSpacing: 9,
              children: [
                for (final hex in palette.take(6))
                  Tooltip(
                    message: hex,
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: colorFromHex(hex),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [
                          BoxShadow(color: Colors.black12, blurRadius: 4),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 13),
            Text(
              'Recommended metals: ${metals.take(2).join(' • ')}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            for (final warning in warnings)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline_rounded, size: 17),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        warning,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 11),
            const Text(
              'Camera-based color is an estimate, not a guaranteed personal-color diagnosis. For the most reliable result, use bright indirect daylight, no filter, and verify the palette in more than one scan.',
              style: TextStyle(
                fontSize: 11.5,
                color: Colors.black54,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MeasurementResults extends StatelessWidget {
  const _MeasurementResults({required this.result, required this.onOpenShop});

  final Map<String, dynamic> result;
  final VoidCallback onOpenShop;

  static const labels = {
    'height': 'Height',
    'neck': 'Neck',
    'shoulder': 'Shoulder',
    'chest': 'Chest / bust',
    'underbust': 'Underbust',
    'waist': 'Natural waist',
    'high_hip': 'High hip',
    'hip': 'Full hip',
    'sleeve': 'Sleeve',
    'wrist': 'Wrist',
    'inseam': 'Inseam',
  };

  @override
  Widget build(BuildContext context) {
    final measurements = result['measurements'] as Map<String, dynamic>;
    final confidence = ((result['scan_confidence'] as num) * 100).round();
    final quality = ((result['image_quality'] as num) * 100).round();
    final personConfidence =
        (((result['person_confidence'] as num?) ?? 1) * 100).round();
    final measurementConfidence =
        (result['measurement_confidence'] as Map<String, dynamic>?) ??
        const <String, dynamic>{};
    final explicitlyDisplayable =
        (result['displayable_measurements'] as List<dynamic>?)
            ?.map((item) => item.toString())
            .toSet();
    bool canShow(String key) =>
        explicitlyDisplayable?.contains(key) ??
        ((measurementConfidence[key] as num?)?.toDouble() ?? 1) >= 0.58;
    final hasReliableFit = {'chest', 'waist', 'hip'}.every(canShow);
    final warnings = (result['quality_warnings'] as List).cast<String>();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'AI body profile',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 5),
            Text(
              'Person detected $personConfidence%  •  Scan confidence $confidence%  •  Image quality $quality%',
            ),
            const SizedBox(height: 6),
            const Text(
              'Only measurements that pass the reliability threshold are shown. Hidden values need a guided or tape-measure scan.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 18),
            LayoutBuilder(
              builder: (context, constraints) {
                final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                final columns = (constraints.maxWidth / (130 * scale))
                    .floor()
                    .clamp(1, 3);
                final width =
                    (constraints.maxWidth - (columns - 1) * 9) / columns;
                return Wrap(
                  spacing: 9,
                  runSpacing: 9,
                  children: [
                    for (final entry in labels.entries)
                      Container(
                        width: width,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: SeamlyColors.sand.withValues(alpha: 0.11),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.value,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.black54,
                              ),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              canShow(entry.key)
                                  ? '${(measurements[entry.key] as num).toStringAsFixed(1)} cm'
                                  : 'Not reliable',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: canShow(entry.key)
                                    ? Colors.black87
                                    : Colors.black38,
                                fontSize: canShow(entry.key) ? 14 : 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            for (final warning in warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.info_outline,
                      size: 17,
                      color: SeamlyColors.sandText,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        warning,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            Text(
              result['validation_status'] as String,
              style: const TextStyle(
                fontSize: 11.5,
                color: Colors.black54,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              result['disclaimer'] as String,
              style: const TextStyle(
                fontSize: 11.5,
                color: Colors.black54,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: hasReliableFit ? onOpenShop : null,
              icon: const Icon(Icons.shopping_cart_rounded),
              label: Text(
                hasReliableFit
                    ? 'Shop my verified fit'
                    : 'Retake for a reliable shop fit',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
