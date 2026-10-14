import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seamly/features/camera_measurement_screen.dart';
import 'package:seamly/features/guided_scan_screen.dart';
import 'package:seamly/services/body_profile_extractor.dart';
import 'package:seamly/services/pose_scan_service.dart';
import 'package:seamly/services/scan_consent.dart';
import 'package:seamly/services/seamly_api.dart';

/// A real 1x1 PNG so Image.memory can decode it.
final _photo = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7l8AAAAASUVORK5CYII=',
);

const _profile = BodyProfile(
  heightCm: 165.0,
  frontWidthsCm: {'chest': 30.0, 'waist': 26.0, 'high_hip': 30.0, 'hip': 34.0},
  sideDepthsCm: {'chest': 21.0, 'waist': 19.0, 'high_hip': 22.0, 'hip': 24.0},
  backWidthsCm: {},
  shoulderCm: 38.0,
  hipToAnkleCm: 80.0,
  warnings: [],
);

final _bodyResult = <String, dynamic>{
  'person_detected': true,
  'scan_confidence': 0.85,
  'image_quality': 0.9,
  'measurements': {
    for (final name in [
      'height',
      'neck',
      'shoulder',
      'chest',
      'underbust',
      'waist',
      'high_hip',
      'hip',
      'sleeve',
      'wrist',
      'inseam',
    ])
      name: 80.0,
  },
  'displayable_measurements': ['chest', 'waist', 'hip'],
  'quality_warnings': <String>[],
  'validation_status': 'Estimated measurements',
  'disclaimer': 'Confirm with a tape measure.',
};

const _colorResult = <String, dynamic>{
  'color_season': 'Soft Autumn',
  'palette': ['#9C7253', '#7A836C', '#DCB38A'],
  'metals': ['Gold'],
  'confidence': 0.8,
  'lighting_quality': 0.85,
  'complexion_direction': 'Warm',
};

/// Sampled color frames, as the selfie screen hands them over.
final List<Map<String, dynamic>> _frames = [
  for (var i = 0; i < 3; i++)
    {
      'skin_rgb': [
        [198, 150, 125],
      ],
    },
];

void main() {
  testWidgets('Body scan opens the camera at once when consent was given', (
    tester,
  ) async {
    _viewport(tester, const Size(430, 900));
    await tester.pumpWidget(_screen(_ScanApi(), _FakeExtractor()));
    expect(find.byKey(const ValueKey('scan-option-body')), findsOneWidget);
    expect(find.byKey(const ValueKey('scan-option-face')), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);

    await _beginScan(tester);
    expect(find.byKey(const ValueKey('fake-scan-done')), findsOneWidget);
    expect(find.byKey(const ValueKey('scan-option-body')), findsNothing);
  });

  testWidgets('the first scan asks for consent once and remembers it', (
    tester,
  ) async {
    _viewport(tester, const Size(430, 900));
    final consent = MemoryScanConsentStore();
    await tester.pumpWidget(
      _screen(_ScanApi(), _FakeExtractor(), consent: consent),
    );
    await _tapKey(tester, 'scan-option-body');
    await tester.pumpAndSettle();
    expect(find.text('Before your first scan'), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-scan-done')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('scan-consent-agree')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-scan-done')), findsOneWidget);
    expect(await consent.isGranted(), isTrue);

    await tester.tap(find.byKey(const ValueKey('fake-scan-cancel')));
    await tester.pump();
    await _tapKey(tester, 'scan-option-body');
    await tester.pumpAndSettle();
    expect(find.text('Before your first scan'), findsNothing);
    expect(find.byKey(const ValueKey('fake-scan-done')), findsOneWidget);
  });

  testWidgets('consent given for the face is not asked again for the body', (
    tester,
  ) async {
    _viewport(tester, const Size(430, 900));
    final consent = MemoryScanConsentStore();
    await tester.pumpWidget(
      _screen(_ScanApi(), _FakeExtractor(), consent: consent),
    );
    await _tapKey(tester, 'scan-option-face');
    await tester.pumpAndSettle();
    expect(find.text('Before your first scan'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('scan-consent-agree')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-face-done')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('fake-face-cancel')));
    await tester.pump();
    await _tapKey(tester, 'scan-option-body');
    await tester.pumpAndSettle();
    expect(find.text('Before your first scan'), findsNothing);
    expect(find.byKey(const ValueKey('fake-scan-done')), findsOneWidget);
  });

  testWidgets('declining consent keeps the scan options', (tester) async {
    _viewport(tester, const Size(430, 900));
    final consent = MemoryScanConsentStore();
    await tester.pumpWidget(
      _screen(_ScanApi(), _FakeExtractor(), consent: consent),
    );
    await _tapKey(tester, 'scan-option-body');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('scan-option-body')), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-scan-done')), findsNothing);
    expect(await consent.isGranted(), isFalse);
  });

  testWidgets('cancelling the camera returns to the scan options', (
    tester,
  ) async {
    _viewport(tester, const Size(430, 900));
    await tester.pumpWidget(_screen(_ScanApi(), _FakeExtractor()));
    await _beginScan(tester);
    await tester.tap(find.byKey(const ValueKey('fake-scan-cancel')));
    await tester.pump();
    expect(find.byKey(const ValueKey('scan-option-body')), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-scan-done')), findsNothing);
  });

  group('body scan', () {
    testWidgets('photos are measured on the phone and only numbers are sent', (
      tester,
    ) async {
      _viewport(tester, const Size(430, 900));
      final api = _ScanApi();
      final extractor = _FakeExtractor();
      var saved = 0;
      String? season;
      await tester.pumpWidget(
        _screen(
          api,
          extractor,
          onMeasurements: (_) => saved++,
          onColor: (value) => season = value,
        ),
      );
      await _beginScan(tester);
      await tester.tap(find.byKey(const ValueKey('fake-scan-done')));
      await tester.pump();
      expect(find.byKey(const ValueKey('scan-progress')), findsOneWidget);
      expect(extractor.heightCm, 165);
      expect(extractor.received!.keys, containsAll(ScanAngle.values));

      await tester.pump();
      expect(api.profileCalls, 1);
      expect(api.profileJson!['height_cm'], 165);
      expect(api.profileJson!.containsKey('image_base64'), isFalse);

      api.profile.complete(_bodyResult);
      await tester.pumpAndSettle();
      expect(saved, 1);
      // Color is no longer analysed from the body photos.
      expect(api.frameCalls, 0);
      expect(season, isNull);
      expect(find.byKey(const ValueKey('scan-progress')), findsNothing);
      expect(find.byKey(const ValueKey('camera-view-results')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a photo problem shows its message and offers a retake', (
      tester,
    ) async {
      _viewport(tester, const Size(430, 900));
      final api = _ScanApi();
      final extractor = _FakeExtractor()
        ..failWith = const ScanExtractionException(
          'Your body outline was not clear enough.',
        );
      await tester.pumpWidget(_screen(api, extractor));
      await _beginScan(tester);
      await tester.tap(find.byKey(const ValueKey('fake-scan-done')));
      await tester.pumpAndSettle();

      expect(
        find.text('Your body outline was not clear enough.'),
        findsOneWidget,
      );
      expect(api.profileCalls, 0);
      expect(find.byKey(const ValueKey('camera-view-results')), findsNothing);

      await tester.ensureVisible(
        find.byKey(const ValueKey('scan-again-button')),
      );
      await tester.tap(find.byKey(const ValueKey('scan-again-button')));
      await tester.pump();
      expect(find.byKey(const ValueKey('fake-scan-done')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a server error is shown and nothing is saved', (tester) async {
      _viewport(tester, const Size(430, 900));
      final api = _ScanApi();
      var saved = 0;
      await tester.pumpWidget(
        _screen(api, _FakeExtractor(), onMeasurements: (_) => saved++),
      );
      await _beginScan(tester);
      await tester.tap(find.byKey(const ValueKey('fake-scan-done')));
      await tester.pump();
      await tester.pump();
      api.profile.completeError(
        const ApiException('The scan did not capture enough of your torso.'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('The scan did not capture enough of your torso.'),
        findsOneWidget,
      );
      expect(api.frameCalls, 0);
      expect(saved, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a late body response cannot save after leaving the scanner', (
      tester,
    ) async {
      _viewport(tester, const Size(430, 900));
      final api = _ScanApi();
      final extractor = _FakeExtractor();
      var saved = 0;
      await tester.pumpWidget(
        _screen(api, extractor, onMeasurements: (_) => saved++),
      );
      await _beginScan(tester);
      await tester.tap(find.byKey(const ValueKey('fake-scan-done')));
      await tester.pump();
      await tester.pump();
      expect(api.profileCalls, 1);

      await tester.pumpWidget(
        _screen(api, extractor, active: false, onMeasurements: (_) => saved++),
      );
      api.profile.complete(_bodyResult);
      await tester.pumpAndSettle();
      expect(saved, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a missing height blocks the body scan but not the face', (
      tester,
    ) async {
      _viewport(tester, const Size(430, 900));
      await tester.pumpWidget(
        _screen(_ScanApi(), _FakeExtractor(), height: null),
      );
      await _tapKey(tester, 'scan-option-body');
      await tester.pumpAndSettle();
      expect(find.textContaining('verified height is missing'), findsOneWidget);
      expect(find.byKey(const ValueKey('fake-scan-done')), findsNothing);

      await _tapKey(tester, 'scan-option-face');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fake-face-done')), findsOneWidget);
    });

    testWidgets('results remain readable on a small screen with large text', (
      tester,
    ) async {
      _viewport(tester, const Size(320, 568));
      final api = _ScanApi();
      api.profile.complete(_bodyResult);
      await tester.pumpWidget(_screen(api, _FakeExtractor(), textScale: 2));
      await _beginScan(tester);
      await tester.tap(find.byKey(const ValueKey('fake-scan-done')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('camera-view-results')),
      );
      await tester.tap(find.byKey(const ValueKey('camera-view-results')));
      await tester.pumpAndSettle();
      expect(find.text('Your scan'), findsOneWidget);
      expect(find.text('Natural waist'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('face colors', () {
    testWidgets('sampled frames are sent and the season is reported', (
      tester,
    ) async {
      _viewport(tester, const Size(430, 900));
      final api = _ScanApi();
      var saved = 0;
      String? season;
      await tester.pumpWidget(
        _screen(
          api,
          _FakeExtractor(),
          onMeasurements: (_) => saved++,
          onColor: (value) => season = value,
        ),
      );
      await _beginFace(tester);
      await tester.tap(find.byKey(const ValueKey('fake-face-done')));
      await tester.pump();
      expect(find.byKey(const ValueKey('scan-progress')), findsOneWidget);
      expect(api.frameCalls, 1);
      expect(api.framesSent, same(_frames));

      api.color.complete(_colorResult);
      await tester.pumpAndSettle();
      expect(season, 'Soft Autumn');
      expect(saved, 0);
      expect(api.profileCalls, 0);
      expect(find.byKey(const ValueKey('scan-progress')), findsNothing);
      expect(find.byKey(const ValueKey('camera-view-results')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('camera-view-results')));
      await tester.pumpAndSettle();
      expect(find.text('Your colors'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('camera-color-analysis-result')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('an analysis error is shown and a retake reopens the selfie', (
      tester,
    ) async {
      _viewport(tester, const Size(430, 900));
      final api = _ScanApi();
      String? season;
      await tester.pumpWidget(
        _screen(api, _FakeExtractor(), onColor: (value) => season = value),
      );
      await _beginFace(tester);
      await tester.tap(find.byKey(const ValueKey('fake-face-done')));
      await tester.pump();
      api.color.completeError(
        const ApiException('Frames disagreed with each other.'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Color analysis needs another scan'), findsOneWidget);
      expect(find.text('Frames disagreed with each other.'), findsOneWidget);
      expect(find.byKey(const ValueKey('camera-view-results')), findsNothing);
      expect(season, isNull);

      await tester.ensureVisible(
        find.byKey(const ValueKey('scan-again-button')),
      );
      await tester.tap(find.byKey(const ValueKey('scan-again-button')));
      await tester.pump();
      expect(find.byKey(const ValueKey('fake-face-done')), findsOneWidget);
      expect(find.byKey(const ValueKey('fake-scan-done')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cancelling the selfie returns to the scan options', (
      tester,
    ) async {
      _viewport(tester, const Size(430, 900));
      await tester.pumpWidget(_screen(_ScanApi(), _FakeExtractor()));
      await _beginFace(tester);
      await tester.tap(find.byKey(const ValueKey('fake-face-cancel')));
      await tester.pump();
      expect(find.byKey(const ValueKey('scan-option-face')), findsOneWidget);
      expect(find.byKey(const ValueKey('fake-face-done')), findsNothing);
    });

    testWidgets('a late color response is ignored after leaving', (
      tester,
    ) async {
      _viewport(tester, const Size(430, 900));
      final api = _ScanApi();
      final extractor = _FakeExtractor();
      var seasons = 0;
      await tester.pumpWidget(
        _screen(api, extractor, onColor: (_) => seasons++),
      );
      await _beginFace(tester);
      await tester.tap(find.byKey(const ValueKey('fake-face-done')));
      await tester.pump();
      expect(api.frameCalls, 1);

      await tester.pumpWidget(
        _screen(api, extractor, active: false, onColor: (_) => seasons++),
      );
      api.color.complete(_colorResult);
      await tester.pumpAndSettle();
      expect(seasons, 0);
      expect(tester.takeException(), isNull);
    });
  });
}

void _viewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pump();
}

/// Taps Body scan (consent already given) and opens the (fake) camera step.
Future<void> _beginScan(WidgetTester tester) async {
  await _tapKey(tester, 'scan-option-body');
  await tester.pumpAndSettle();
}

/// Taps Face colors (consent already given) and opens the (fake) selfie step.
Future<void> _beginFace(WidgetTester tester) async {
  await _tapKey(tester, 'scan-option-face');
  await tester.pumpAndSettle();
}

Map<ScanAngle, ScanShot> _shots() => {
  for (final angle in ScanAngle.values)
    angle: ScanShot(
      angle: angle,
      jpegBytes: angle == ScanAngle.front
          ? _photo
          : Uint8List.fromList([angle.index]),
      keyPoints: const {},
    ),
};

Widget _screen(
  _ScanApi api,
  _FakeExtractor extractor, {
  bool active = true,
  ValueChanged<Map<String, double>>? onMeasurements,
  ValueChanged<String>? onColor,
  double textScale = 1,
  ScanConsentStore? consent,
  double? height = 165,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: CameraMeasurementScreen(
      api: api,
      active: active,
      referenceHeightCm: height,
      onBack: () {},
      onMeasurementsReady: onMeasurements ?? (_) {},
      onColorSeasonAnalyzed: onColor ?? (_) {},
      onOpenShop: () {},
      consentStore: consent ?? MemoryScanConsentStore(granted: true),
      extractor: extractor,
      scanBuilder: (onCompleted, onCancel) =>
          _FakeScan(onCompleted: onCompleted, onCancel: onCancel),
      faceBuilder: (onCompleted, onCancel) =>
          _FakeFace(onCompleted: onCompleted, onCancel: onCancel),
    ),
  ),
);

/// Stands in for the guided body camera: two buttons instead of a preview.
class _FakeScan extends StatelessWidget {
  const _FakeScan({required this.onCompleted, required this.onCancel});

  final ValueChanged<Map<ScanAngle, ScanShot>> onCompleted;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextButton(
        key: const ValueKey('fake-scan-done'),
        onPressed: () => onCompleted(_shots()),
        child: const Text('Finish fake scan'),
      ),
      TextButton(
        key: const ValueKey('fake-scan-cancel'),
        onPressed: onCancel,
        child: const Text('Cancel fake scan'),
      ),
    ],
  );
}

/// Stands in for the selfie camera: two buttons instead of a preview.
class _FakeFace extends StatelessWidget {
  const _FakeFace({required this.onCompleted, required this.onCancel});

  final ValueChanged<List<Map<String, dynamic>>> onCompleted;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextButton(
        key: const ValueKey('fake-face-done'),
        onPressed: () => onCompleted(_frames),
        child: const Text('Finish fake selfie'),
      ),
      TextButton(
        key: const ValueKey('fake-face-cancel'),
        onPressed: onCancel,
        child: const Text('Cancel fake selfie'),
      ),
    ],
  );
}

class _FakeExtractor implements BodyProfileExtractor {
  Object? failWith;
  Map<ScanAngle, ScanShot>? received;
  double? heightCm;

  @override
  Future<BodyProfile> extract({
    required Map<ScanAngle, ScanShot> shots,
    required double heightCm,
  }) async {
    received = shots;
    this.heightCm = heightCm;
    final failure = failWith;
    if (failure != null) throw failure;
    return _profile;
  }

  @override
  Future<void> dispose() async {}
}

class _ScanApi extends SeamlyApi {
  final profile = Completer<Map<String, dynamic>>();
  final color = Completer<Map<String, dynamic>>();
  int profileCalls = 0;
  int frameCalls = 0;
  Map<String, dynamic>? profileJson;
  List<Map<String, dynamic>>? framesSent;

  @override
  Future<Map<String, dynamic>> analyzeBodyProfile(
    Map<String, dynamic> profileJson,
  ) {
    profileCalls++;
    this.profileJson = profileJson;
    return profile.future;
  }

  @override
  Future<Map<String, dynamic>> analyzeColorFrames(
    List<Map<String, dynamic>> frames,
  ) {
    frameCalls++;
    framesSent = frames;
    return color.future;
  }
}
