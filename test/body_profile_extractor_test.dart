import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:seamly/features/guided_scan_screen.dart' show ScanShot;
import 'package:seamly/services/body_profile_extractor.dart';
import 'package:seamly/services/pose_scan_service.dart';

// Synthetic photo: 300 x 400 pixels, so aspect (width / height) is 0.75.
// The body fills rows 20..379, i.e. 0.90 of the image height.
//
// With a saved height of 180 cm:
//   cm per row    = 180 / 0.90        = 200
//   cm per column = 200 * 0.75        = 150 (per unit of image width)
// so a body run that is 73 pixels wide measures 73 / 300 * 150 = 36.5 cm.
const _w = 300;
const _h = 400;
const _aspect = 0.75;
const _height = 180.0;
const _centerX = 150;

/// Builds a mask. [halfWidth] returns how far the body reaches left and right
/// of the centre line on row y (so the run is 2 * half + 1 pixels), or -1 for
/// an empty row.
BodySilhouette _mask(int Function(int y) halfWidth) {
  final fg = Uint8List(_w * _h);
  for (var y = 0; y < _h; y++) {
    final half = halfWidth(y);
    if (half < 0) continue;
    for (var x = _centerX - half; x <= _centerX + half; x++) {
      fg[y * _w + x] = 1;
    }
  }
  return BodySilhouette(fg, _w, _h, _aspect);
}

/// Front view. Zones line up with the measurement levels for [_frontPoints]:
/// chest ~row 136, waist ~182, high hip ~206, hip ~230 (each read +/- 5 rows).
int _frontHalf(int y, {int chest = 36}) {
  if (y < 20 || y > 379) return -1;
  if (y < 100) return 15; // head and neck
  if (y < 160) return chest;
  if (y < 196) return 30; // waist
  if (y < 220) return 34; // high hip
  if (y < 260) return 38; // hip
  return 25; // legs
}

/// Side view: thinner torso than the front.
int _sideHalf(int y) {
  if (y < 20 || y > 379) return -1;
  if (y < 100) return 15;
  if (y < 160) return 24;
  if (y < 196) return 21;
  if (y < 220) return 24;
  if (y < 260) return 26;
  return 20;
}

Map<String, Offset> _frontPoints() => const {
  'lShoulder': Offset(0.63, 0.25),
  'rShoulder': Offset(0.37, 0.25),
  'lHip': Offset(0.56, 0.55),
  'rHip': Offset(0.44, 0.55),
  'lAnkle': Offset(0.55, 0.85),
  'rAnkle': Offset(0.45, 0.85),
};

Map<String, Offset> _sidePoints() => const {
  'lShoulder': Offset(0.52, 0.25),
  'rShoulder': Offset(0.48, 0.25),
  'lHip': Offset(0.52, 0.55),
  'rHip': Offset(0.48, 0.55),
  'lAnkle': Offset(0.52, 0.85),
  'rAnkle': Offset(0.48, 0.85),
};

ScanShot _shot(ScanAngle angle, Map<String, Offset> points) => ScanShot(
  angle: angle,
  // The loader below picks the silhouette by this single byte.
  jpegBytes: Uint8List.fromList([angle.index]),
  keyPoints: points,
);

Map<ScanAngle, ScanShot> _shots({bool back = false}) => {
  ScanAngle.front: _shot(ScanAngle.front, _frontPoints()),
  ScanAngle.side: _shot(ScanAngle.side, _sidePoints()),
  if (back) ScanAngle.back: _shot(ScanAngle.back, _frontPoints()),
};

/// An extractor whose "segmentation" returns the given masks.
BodyProfileExtractor _extractor({
  BodySilhouette? front,
  BodySilhouette? side,
  Object? back,
}) {
  final frontMask = front ?? _mask(_frontHalf);
  final sideMask = side ?? _mask(_sideHalf);
  return BodyProfileExtractor(
    silhouetteLoader: (jpeg) async {
      switch (ScanAngle.values[jpeg.first]) {
        case ScanAngle.front:
          return frontMask;
        case ScanAngle.side:
          return sideMask;
        case ScanAngle.back:
          final result = back ?? _mask((y) => _frontHalf(y, chest: 35));
          if (result is BodySilhouette) return result;
          throw result;
      }
    },
  );
}

Matcher _extractionError(Pattern message) => throwsA(
  isA<ScanExtractionException>().having(
    (e) => e.message,
    'message',
    contains(message),
  ),
);

void main() {
  group('front and side photos', () {
    test('measure torso widths and depths in centimetres', () async {
      final profile = await _extractor().extract(
        shots: _shots(),
        heightCm: _height,
      );
      expect(profile.heightCm, _height);
      expect(profile.frontWidthsCm['chest'], closeTo(36.5, 0.6));
      expect(profile.frontWidthsCm['waist'], closeTo(30.5, 0.6));
      expect(profile.frontWidthsCm['high_hip'], closeTo(34.5, 0.6));
      expect(profile.frontWidthsCm['hip'], closeTo(38.5, 0.6));
      expect(profile.sideDepthsCm['chest'], closeTo(24.5, 0.6));
      expect(profile.sideDepthsCm['waist'], closeTo(21.5, 0.6));
      expect(profile.sideDepthsCm['high_hip'], closeTo(24.5, 0.6));
      expect(profile.sideDepthsCm['hip'], closeTo(26.5, 0.6));
      expect(profile.backWidthsCm, isEmpty);
      expect(profile.warnings, isEmpty);
    });

    test('shoulder width and hip-to-ankle come from the front photo', () async {
      final profile = await _extractor().extract(
        shots: _shots(),
        heightCm: _height,
      );
      // 0.26 of image width * 150 cm; 0.30 of image height * 200 cm.
      expect(profile.shoulderCm, closeTo(39.0, 0.5));
      expect(profile.hipToAnkleCm, closeTo(60.0, 0.5));
    });

    test('every measurement scales with the saved height', () async {
      final tall = await _extractor().extract(shots: _shots(), heightCm: 180);
      final short = await _extractor().extract(shots: _shots(), heightCm: 160);
      expect(
        tall.frontWidthsCm['waist']! / short.frontWidthsCm['waist']!,
        closeTo(180 / 160, 1e-6),
      );
      expect(
        tall.sideDepthsCm['hip']! / short.sideDepthsCm['hip']!,
        closeTo(180 / 160, 1e-6),
      );
    });

    test('arms touching the torso are capped and reported', () async {
      final profile = await _extractor(
        front: _mask((y) => _frontHalf(y, chest: 48)),
      ).extract(shots: _shots(), heightCm: _height);
      // Shoulder width 0.26 * 1.05 = 0.273 of image width * 150 cm.
      expect(profile.frontWidthsCm['chest'], closeTo(40.95, 0.05));
      expect(
        profile.warnings.where((w) => w.contains('arms may touch')),
        hasLength(1),
      );
    });
  });

  group('back photo', () {
    test('is measured and returned when it works', () async {
      final profile = await _extractor().extract(
        shots: _shots(back: true),
        heightCm: _height,
      );
      expect(profile.backWidthsCm['chest'], closeTo(35.5, 0.6));
      expect(profile.backWidthsCm.keys, containsAll(['chest', 'waist', 'hip']));
      expect(profile.warnings, isEmpty);
    });

    test('a bad back photo only adds a warning', () async {
      final profile = await _extractor(
        back: const ScanExtractionException('No person was found in a photo.'),
      ).extract(shots: _shots(back: true), heightCm: _height);
      expect(profile.backWidthsCm, isEmpty);
      expect(profile.frontWidthsCm, isNotEmpty);
      expect(
        profile.warnings,
        contains('Back photo skipped: No person was found in a photo.'),
      );
    });
  });

  group('failures', () {
    test('front and side are both required', () async {
      final extractor = _extractor();
      await expectLater(
        extractor.extract(
          shots: {ScanAngle.front: _shot(ScanAngle.front, _frontPoints())},
          heightCm: _height,
        ),
        _extractionError('front and side photos are both required'),
      );
      await expectLater(
        extractor.extract(
          shots: {ScanAngle.side: _shot(ScanAngle.side, _sidePoints())},
          heightCm: _height,
        ),
        _extractionError('front and side photos are both required'),
      );
    });

    test('missing body points are rejected', () async {
      await expectLater(
        _extractor().extract(
          shots: {
            ScanAngle.front: _shot(ScanAngle.front, const {}),
            ScanAngle.side: _shot(ScanAngle.side, _sidePoints()),
          },
          heightCm: _height,
        ),
        _extractionError('Body points were missing.'),
      );
    });

    test('a pose with hips above the shoulders is not upright', () async {
      final upsideDown = {
        ..._frontPoints(),
        'lHip': const Offset(0.56, 0.20),
        'rHip': const Offset(0.44, 0.20),
      };
      await expectLater(
        _extractor().extract(
          shots: {
            ScanAngle.front: _shot(ScanAngle.front, upsideDown),
            ScanAngle.side: _shot(ScanAngle.side, _sidePoints()),
          },
          heightCm: _height,
        ),
        _extractionError('The body pose was not upright.'),
      );
    });

    test('an empty mask means no full body was found', () async {
      await expectLater(
        _extractor(front: _mask((_) => -1)).extract(
          shots: _shots(),
          heightCm: _height,
        ),
        _extractionError('Your full body was not found in the photo.'),
      );
    });

    test('a body shorter than half the image is not a full body', () async {
      await expectLater(
        _extractor(
          front: _mask((y) => y >= 20 && y <= 120 ? 20 : -1),
        ).extract(shots: _shots(), heightCm: _height),
        _extractionError('Your full body was not found in the photo.'),
      );
    });

    test('unreadable torso levels ask for a retake', () async {
      // The head and legs exist, but the whole torso band is empty.
      int gapped(int y) => y >= 125 && y <= 240 ? -1 : _frontHalf(y);
      await expectLater(
        _extractor(front: _mask(gapped)).extract(
          shots: _shots(),
          heightCm: _height,
        ),
        _extractionError('not clear enough'),
      );
    });
  });

  group('BodyProfile.toJson', () {
    test('rounds to one decimal and uses the backend keys', () {
      const profile = BodyProfile(
        heightCm: 165,
        frontWidthsCm: {'chest': 30.04, 'waist': 26.26},
        sideDepthsCm: {'chest': 21.0},
        backWidthsCm: {},
        shoulderCm: 38.06,
        hipToAnkleCm: 60.06,
        warnings: ['note'],
      );
      final json = profile.toJson();
      expect(json['height_cm'], 165);
      expect(json['front_widths_cm'], {'chest': 30.0, 'waist': 26.3});
      expect(json['side_depths_cm'], {'chest': 21.0});
      expect(json['back_widths_cm'], isEmpty);
      expect(json['shoulder_cm'], 38.1);
      expect(json['hip_to_ankle_cm'], 60.1);
      expect(json['warnings'], ['note']);
    });

    test('leaves out shoulder and hip-to-ankle when unknown', () {
      const profile = BodyProfile(
        heightCm: 165,
        frontWidthsCm: {},
        sideDepthsCm: {},
        backWidthsCm: {},
        shoulderCm: null,
        hipToAnkleCm: null,
        warnings: [],
      );
      final json = profile.toJson();
      expect(json.containsKey('shoulder_cm'), isFalse);
      expect(json.containsKey('hip_to_ankle_cm'), isFalse);
    });
  });

  test('dispose is safe when no segmenter was ever created', () async {
    await _extractor().dispose();
  });
}
