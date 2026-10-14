import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';
import 'package:image/image.dart' as img;

import '../features/guided_scan_screen.dart' show ScanShot;
import 'pose_scan_service.dart';

/// Where on the torso each measurement is taken, as a fraction of the way
/// from the shoulder line to the hip line. Tune on real people.
abstract final class BodyLevels {
  static const chest = 0.30;
  static const waist = 0.68;

  /// Full hip sits a little below the hip joint, as a fraction of hip->ankle.
  static const hipBelowJoint = 0.08;

  /// Rows sampled above/below each level, as a fraction of image height.
  static const bandHalfHeight = 0.012;

  /// Guards against arms merging with the torso in front/back photos.
  static const shoulderCap = 1.05;
  static const hipCap = 2.3;
}

class ScanExtractionException implements Exception {
  const ScanExtractionException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Everything the backend needs to finish the measurements.
/// All values are centimetres, derived from the user's saved height.
class BodyProfile {
  const BodyProfile({
    required this.heightCm,
    required this.frontWidthsCm,
    required this.sideDepthsCm,
    required this.backWidthsCm,
    required this.shoulderCm,
    required this.hipToAnkleCm,
    required this.warnings,
  });

  final double heightCm;
  final Map<String, double> frontWidthsCm;
  final Map<String, double> sideDepthsCm;
  final Map<String, double> backWidthsCm;
  final double? shoulderCm;
  final double? hipToAnkleCm;
  final List<String> warnings;

  static double _r(double v) => (v * 10).roundToDouble() / 10;
  static Map<String, double> _rounded(Map<String, double> m) => {
    for (final e in m.entries) e.key: _r(e.value),
  };

  Map<String, dynamic> toJson() => {
    'height_cm': heightCm,
    'front_widths_cm': _rounded(frontWidthsCm),
    'side_depths_cm': _rounded(sideDepthsCm),
    'back_widths_cm': _rounded(backWidthsCm),
    if (shoulderCm != null) 'shoulder_cm': _r(shoulderCm!),
    if (hipToAnkleCm != null) 'hip_to_ankle_cm': _r(hipToAnkleCm!),
    'warnings': warnings,
  };
}

/// Turns the three scan photos plus pose points into body widths and depths.
/// Runs on the phone; only the resulting numbers go to the backend.
class BodyProfileExtractor {
  /// [silhouetteLoader] replaces the on-device segmentation step. Tests use it
  /// to hand in synthetic silhouettes; the real app leaves it null.
  BodyProfileExtractor({
    SelfieSegmenter? segmenter,
    Future<BodySilhouette> Function(Uint8List jpeg)? silhouetteLoader,
  }) : _segmenter = segmenter,
       _loader = silhouetteLoader;

  /// Created on first use, so building an extractor never touches ML Kit.
  SelfieSegmenter? _segmenter;
  final Future<BodySilhouette> Function(Uint8List jpeg)? _loader;

  Future<void> dispose() async {
    await _segmenter?.close();
  }

  Future<BodyProfile> extract({
    required Map<ScanAngle, ScanShot> shots,
    required double heightCm,
  }) async {
    final front = shots[ScanAngle.front];
    final side = shots[ScanAngle.side];
    if (front == null || side == null) {
      throw const ScanExtractionException(
        'The front and side photos are both required.',
      );
    }
    final warnings = <String>[];
    final f = await _measure(front, heightCm, warnings, 'front', false);
    final s = await _measure(side, heightCm, warnings, 'side', true);

    _ShotMeasure? b;
    final back = shots[ScanAngle.back];
    if (back != null) {
      try {
        b = await _measure(back, heightCm, warnings, 'back', false);
      } on ScanExtractionException catch (error) {
        warnings.add('Back photo skipped: ${error.message}');
      }
    }

    if (f.levels.length < 3 || s.levels.length < 3) {
      throw const ScanExtractionException(
        'Your body outline was not clear enough. Retake the scan in good light, with your whole body in view.',
      );
    }
    return BodyProfile(
      heightCm: heightCm,
      frontWidthsCm: f.levels,
      sideDepthsCm: s.levels,
      backWidthsCm: b?.levels ?? const {},
      shoulderCm: f.shoulderCm,
      hipToAnkleCm: f.hipToAnkleCm,
      warnings: warnings.toSet().toList(),
    );
  }

  Future<_ShotMeasure> _measure(
    ScanShot shot,
    double heightCm,
    List<String> warnings,
    String label,
    bool isSide,
  ) async {
    final sil = await _silhouette(shot.jpegBytes);
    final kp = shot.keyPoints;
    Offset? p(String key) => kp[key];
    final ls = p('lShoulder'), rs = p('rShoulder');
    final lh = p('lHip'), rh = p('rHip');
    final la = p('lAnkle'), ra = p('rAnkle');
    if (ls == null ||
        rs == null ||
        lh == null ||
        rh == null ||
        la == null ||
        ra == null) {
      throw const ScanExtractionException('Body points were missing.');
    }

    final centerX = (ls.dx + rs.dx + lh.dx + rh.dx) / 4;
    final shoulderY = (ls.dy + rs.dy) / 2;
    final hipY = (lh.dy + rh.dy) / 2;
    final ankleY = (la.dy + ra.dy) / 2;
    final torso = hipY - shoulderY;
    if (torso <= 0) {
      throw const ScanExtractionException('The body pose was not upright.');
    }

    final extent = _verticalExtent(sil, centerX);
    if (extent == null || extent.$2 - extent.$1 < 0.5) {
      throw const ScanExtractionException(
        'Your full body was not found in the photo.',
      );
    }
    final heightNorm = extent.$2 - extent.$1;
    final cmPerY = heightCm / heightNorm;
    final cmPerX = cmPerY * sil.aspect;

    final hipLevelY = hipY + BodyLevels.hipBelowJoint * (ankleY - hipY);
    final waistY = shoulderY + BodyLevels.waist * torso;
    final levels = <String, double>{
      'chest': shoulderY + BodyLevels.chest * torso,
      'waist': waistY,
      'high_hip': (waistY + hipLevelY) / 2,
      'hip': hipLevelY,
    };

    final shoulderNorm = (ls.dx - rs.dx).abs();
    final hipNorm = (lh.dx - rh.dx).abs();
    final result = <String, double>{};
    var armsWarned = false;
    for (final entry in levels.entries) {
      var run = _runWidth(sil, entry.value, centerX);
      if (run == null) {
        warnings.add('Could not read your $label ${entry.key}.');
        continue;
      }
      if (!isSide) {
        final cap = entry.key == 'chest' || entry.key == 'waist'
            ? shoulderNorm * BodyLevels.shoulderCap
            : hipNorm * BodyLevels.hipCap;
        if (cap > 0 && run > cap) {
          run = cap;
          if (!armsWarned) {
            warnings.add(
              'In the $label photo your arms may touch your body. Keep them slightly away next time.',
            );
            armsWarned = true;
          }
        }
      }
      result[entry.key] = run * cmPerX;
    }

    return _ShotMeasure(
      levels: result,
      shoulderCm: isSide ? null : shoulderNorm * cmPerX,
      hipToAnkleCm: (ankleY - hipY) * cmPerY,
    );
  }

  Future<BodySilhouette> _silhouette(Uint8List jpeg) {
    final loader = _loader;
    return loader != null ? loader(jpeg) : _segmentOnDevice(jpeg);
  }

  Future<BodySilhouette> _segmentOnDevice(Uint8List jpeg) async {
    final prepared = await Isolate.run(() => _prepare(jpeg));
    if (prepared == null) {
      throw const ScanExtractionException('A photo could not be read.');
    }
    final directory = await Directory.systemTemp.createTemp('seamly-scan');
    try {
      final path = '${directory.path}/shot.jpg';
      await File(path).writeAsBytes(prepared.bytes, flush: true);
      final segmenter = _segmenter ??= SelfieSegmenter(
        mode: SegmenterMode.single,
      );
      final mask = await segmenter.processImage(InputImage.fromFilePath(path));
      if (mask == null ||
          mask.width <= 0 ||
          mask.height <= 0 ||
          mask.confidences.length < mask.width * mask.height) {
        throw const ScanExtractionException(
          'No person was found in a photo.',
        );
      }
      final foreground = Uint8List(mask.width * mask.height);
      for (var i = 0; i < foreground.length; i++) {
        foreground[i] = mask.confidences[i] >= 0.5 ? 1 : 0;
      }
      return BodySilhouette(
        foreground,
        mask.width,
        mask.height,
        prepared.width / prepared.height,
      );
    } finally {
      try {
        await directory.delete(recursive: true);
      } on Exception {
        // Best-effort temp cleanup.
      }
    }
  }

  /// Top and bottom of the body (0..1), judged near the body centre so stray
  /// background objects do not stretch the height.
  (double, double)? _verticalExtent(BodySilhouette sil, double centerX) {
    final from = ((centerX - 0.2) * sil.w).floor().clamp(0, sil.w - 1);
    final to = ((centerX + 0.2) * sil.w).ceil().clamp(1, sil.w);
    int? top, bottom;
    for (var y = 0; y < sil.h; y++) {
      var count = 0;
      for (var x = from; x < to; x++) {
        if (sil.at(x, y)) count++;
      }
      if (count >= 2) {
        top ??= y;
        bottom = y;
      }
    }
    if (top == null || bottom == null) return null;
    return (top / sil.h, (bottom + 1) / sil.h);
  }

  /// Width (0..1 of image width) of the body run that contains the centre
  /// line, taken as the median over a thin band of rows.
  double? _runWidth(BodySilhouette sil, double yNorm, double centerNorm) {
    final centerRow = (yNorm * sil.h).round();
    final band = math.max(1, (BodyLevels.bandHalfHeight * sil.h).round());
    final widths = <double>[];
    for (var y = centerRow - band; y <= centerRow + band; y++) {
      if (y < 0 || y >= sil.h) continue;
      var x = (centerNorm * sil.w).round().clamp(0, sil.w - 1);
      if (!sil.at(x, y)) {
        final reach = (0.08 * sil.w).round();
        int? found;
        for (var d = 1; d <= reach && found == null; d++) {
          if (x - d >= 0 && sil.at(x - d, y)) {
            found = x - d;
          } else if (x + d < sil.w && sil.at(x + d, y)) {
            found = x + d;
          }
        }
        if (found == null) continue;
        x = found;
      }
      final left = _edge(sil, x, -1, y);
      final right = _edge(sil, x, 1, y);
      widths.add((right - left + 1) / sil.w);
    }
    if (widths.length < 2) return null;
    widths.sort();
    return widths[widths.length ~/ 2];
  }

  /// Walk outwards while pixels are body, tolerating a one-pixel gap.
  int _edge(BodySilhouette sil, int start, int step, int y) {
    var edge = start;
    var gap = 0;
    var i = start + step;
    while (i >= 0 && i < sil.w) {
      if (sil.at(i, y)) {
        edge = i;
        gap = 0;
      } else if (++gap > 1) {
        break;
      }
      i += step;
    }
    return edge;
  }
}

class _ShotMeasure {
  const _ShotMeasure({
    required this.levels,
    required this.shoulderCm,
    required this.hipToAnkleCm,
  });

  final Map<String, double> levels;
  final double? shoulderCm;
  final double hipToAnkleCm;
}

/// A person mask: [fg] holds one byte per pixel (1 = body), row by row.
/// Public so tests can build synthetic silhouettes.
class BodySilhouette {
  const BodySilhouette(this.fg, this.w, this.h, this.aspect);

  final Uint8List fg;
  final int w;
  final int h;

  /// Photo width / height, needed to convert x units to centimetres.
  final double aspect;

  bool at(int x, int y) => fg[y * w + x] == 1;
}

/// Runs in a background isolate: decode, apply EXIF rotation, shrink.
({Uint8List bytes, int width, int height})? _prepare(Uint8List jpeg) {
  final decoded = img.decodeImage(jpeg);
  if (decoded == null) return null;
  var image = img.bakeOrientation(decoded);
  if (image.height > 640) {
    image = img.copyResize(
      image,
      height: 640,
      interpolation: img.Interpolation.average,
    );
  }
  return (
    bytes: Uint8List.fromList(img.encodeJpg(image, quality: 92)),
    width: image.width,
    height: image.height,
  );
}
