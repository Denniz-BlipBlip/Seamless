import 'dart:ui' show Offset, Rect;

import 'package:image/image.dart' as img;

/// Thresholds in one place so they can be tuned on real phones.
abstract final class SelfieTuning {
  /// Each patch is sampled on a steps x steps grid.
  static const gridSteps = 9;

  /// Face width / photo width below this means "too far away".
  static const minFaceWidthFraction = 0.28;

  /// Head turn (yaw) beyond this many degrees is not facing the camera.
  static const maxHeadTurnDegrees = 15.0;

  /// Mean skin luminance (0-255) outside this range is too dark / too bright.
  static const minSkinLuma = 70.0;
  static const maxSkinLuma = 215.0;

  /// Left vs right cheek brightness gap (fraction) that counts as uneven light.
  static const maxSideImbalance = 0.22;

  /// Eye whites must be nearly neutral (max channel minus min channel).
  static const whiteMaxSpread = 45;

  /// A channel at or above this is clipped and cannot be trusted.
  static const clippedChannel = 250;

  static const minWhitePixels = 5;
  static const maxWhitePixels = 200;
  static const minPatchPixels = 20;
}

class SelfieSampleException implements Exception {
  const SelfieSampleException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Face points in photo pixels, as reported by face detection.
class FaceGeometry {
  const FaceGeometry({
    required this.faceBox,
    required this.leftEye,
    required this.rightEye,
    required this.mouthLeft,
    required this.mouthRight,
    this.leftEyeContour = const [],
    this.rightEyeContour = const [],
    this.headYawDegrees = 0,
  });

  final Rect faceBox;
  final Offset leftEye;
  final Offset rightEye;
  final Offset mouthLeft;
  final Offset mouthRight;

  /// Outline of each eye opening. Needed to find the eye whites.
  final List<Offset> leftEyeContour;
  final List<Offset> rightEyeContour;
  final double headYawDegrees;
}

/// Colors sampled from one frame. This, not the photo, is what gets sent.
class SelfieSample {
  const SelfieSample({
    required this.skin,
    required this.white,
    required this.hair,
    required this.eye,
    required this.problems,
  });

  final List<List<int>> skin;
  final List<List<int>>? white;
  final List<int>? hair;
  final List<int>? eye;

  /// Reasons this frame should not be used. Empty means it is ready.
  final List<String> problems;

  bool get ready => problems.isEmpty;

  /// Matches the backend's `ColorFrame` model.
  Map<String, dynamic> toJson() => {
    'skin_rgb': skin,
    if (white != null) 'white_rgb': white,
    if (hair != null) 'hair_rgb': hair,
    if (eye != null) 'eye_rgb': eye,
  };
}

/// Reads skin, eye-white, hair and iris colors from a decoded photo, using
/// face points. Pure logic: no camera, no ML Kit, easy to unit test.
class SelfieSampler {
  const SelfieSampler();

  SelfieSample sample(img.Image image, FaceGeometry face) {
    final problems = <String>[];
    if (face.faceBox.width / image.width < SelfieTuning.minFaceWidthFraction) {
      problems.add('Move closer so your face fills more of the frame.');
    }
    if (face.headYawDegrees.abs() > SelfieTuning.maxHeadTurnDegrees) {
      problems.add('Face the camera straight on.');
    }

    final eyeDistance = (face.rightEye - face.leftEye).distance;
    if (eyeDistance <= 0) {
      throw const SelfieSampleException('Face points were missing.');
    }
    final eyeMid = Offset(
      (face.leftEye.dx + face.rightEye.dx) / 2,
      (face.leftEye.dy + face.rightEye.dy) / 2,
    );
    final mouthMid = Offset(
      (face.mouthLeft.dx + face.mouthRight.dx) / 2,
      (face.mouthLeft.dy + face.mouthRight.dy) / 2,
    );
    final half = 0.2 * eyeDistance;

    Rect cheek(Offset eye) => Rect.fromCenter(
      center: Offset(eye.dx, eye.dy + 0.55 * (mouthMid.dy - eye.dy)),
      width: half * 2,
      height: half * 2,
    );

    final cheekA = _grid(image, cheek(face.leftEye));
    final cheekB = _grid(image, cheek(face.rightEye));
    if (cheekA.length < SelfieTuning.minPatchPixels ||
        cheekB.length < SelfieTuning.minPatchPixels) {
      throw const SelfieSampleException(
        'Your cheeks are outside the photo. Center your face.',
      );
    }
    final skin = <List<int>>[...cheekA, ...cheekB];

    final foreheadRect = Rect.fromCenter(
      center: Offset(eyeMid.dx, eyeMid.dy - 0.6 * eyeDistance),
      width: half * 2,
      height: 0.24 * eyeDistance,
    );
    if (foreheadRect.top >= face.faceBox.top) {
      skin.addAll(_grid(image, foreheadRect));
    }

    final lumaA = _meanLuma(cheekA);
    final lumaB = _meanLuma(cheekB);
    final lumaAll = _meanLuma(skin);
    if (lumaAll < SelfieTuning.minSkinLuma) {
      problems.add('Too dark. Move to bright, even daylight.');
    } else if (lumaAll > SelfieTuning.maxSkinLuma) {
      problems.add('Too bright. Step out of direct light.');
    }
    final brighter = lumaA > lumaB ? lumaA : lumaB;
    if (brighter > 0 &&
        (lumaA - lumaB).abs() / brighter > SelfieTuning.maxSideImbalance) {
      problems.add('One side of your face is brighter. Face the light evenly.');
    }

    final eyePixels = <List<int>>[
      ..._insidePolygon(image, face.leftEyeContour),
      ..._insidePolygon(image, face.rightEyeContour),
    ];
    final white = _eyeWhites(eyePixels);
    if (white == null) {
      problems.add('Open your eyes wide so the whites of your eyes are visible.');
    }
    final eye = _irisColor(eyePixels);

    List<int>? hair;
    final hairRect = Rect.fromLTRB(
      face.faceBox.center.dx - 0.2 * face.faceBox.width,
      face.faceBox.top - 0.14 * face.faceBox.height,
      face.faceBox.center.dx + 0.2 * face.faceBox.width,
      face.faceBox.top - 0.03 * face.faceBox.height,
    );
    if (hairRect.top >= 0) {
      final hairPixels = _grid(image, hairRect);
      if (hairPixels.length >= SelfieTuning.minPatchPixels) {
        hair = _medianColor(hairPixels);
      }
    }

    return SelfieSample(
      skin: skin,
      white: white,
      hair: hair,
      eye: eye,
      problems: problems,
    );
  }

  /// Near-neutral, unclipped, brighter half of the eye-opening pixels.
  List<List<int>>? _eyeWhites(List<List<int>> pixels) {
    final candidates = pixels.where((c) {
      final high = c.reduce((a, b) => a > b ? a : b);
      final low = c.reduce((a, b) => a < b ? a : b);
      return high - low <= SelfieTuning.whiteMaxSpread &&
          high < SelfieTuning.clippedChannel;
    }).toList();
    if (candidates.length < SelfieTuning.minWhitePixels) return null;
    candidates.sort((a, b) => _luma(b).compareTo(_luma(a)));
    final keep = (candidates.length / 2).ceil().clamp(
      SelfieTuning.minWhitePixels,
      SelfieTuning.maxWhitePixels,
    );
    if (keep > candidates.length) return null;
    return candidates.sublist(0, keep);
  }

  /// Darker-middle slice of the eye opening: past the pupil and lashes
  /// (darkest 10%), before the whites (above 35%).
  List<int>? _irisColor(List<List<int>> pixels) {
    if (pixels.length < 10) return null;
    final sorted = [...pixels]..sort((a, b) => _luma(a).compareTo(_luma(b)));
    final from = (sorted.length * 0.10).floor();
    final to = (sorted.length * 0.35).ceil();
    if (to - from < 3) return null;
    return _medianColor(sorted.sublist(from, to));
  }

  List<List<int>> _grid(img.Image image, Rect rect) {
    const steps = SelfieTuning.gridSteps;
    final out = <List<int>>[];
    for (var i = 0; i < steps; i++) {
      for (var j = 0; j < steps; j++) {
        final x = (rect.left + (i + 0.5) * rect.width / steps).floor();
        final y = (rect.top + (j + 0.5) * rect.height / steps).floor();
        if (x < 0 || y < 0 || x >= image.width || y >= image.height) continue;
        out.add(_pixel(image, x, y));
      }
    }
    return out;
  }

  List<List<int>> _insidePolygon(img.Image image, List<Offset> polygon) {
    if (polygon.length < 3) return const [];
    var minX = polygon.first.dx, maxX = polygon.first.dx;
    var minY = polygon.first.dy, maxY = polygon.first.dy;
    for (final p in polygon) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    final out = <List<int>>[];
    for (var y = minY.floor(); y <= maxY.ceil(); y++) {
      for (var x = minX.floor(); x <= maxX.ceil(); x++) {
        if (x < 0 || y < 0 || x >= image.width || y >= image.height) continue;
        if (_contains(polygon, x + 0.5, y + 0.5)) out.add(_pixel(image, x, y));
      }
    }
    return out;
  }

  /// Ray casting point-in-polygon test.
  bool _contains(List<Offset> polygon, double x, double y) {
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final a = polygon[i];
      final b = polygon[j];
      final crosses =
          (a.dy > y) != (b.dy > y) &&
          x < (b.dx - a.dx) * (y - a.dy) / (b.dy - a.dy) + a.dx;
      if (crosses) inside = !inside;
    }
    return inside;
  }

  List<int> _pixel(img.Image image, int x, int y) {
    final p = image.getPixel(x, y);
    return [p.r.toInt(), p.g.toInt(), p.b.toInt()];
  }

  double _luma(List<int> c) => 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];

  double _meanLuma(List<List<int>> pixels) =>
      pixels.map(_luma).reduce((a, b) => a + b) / pixels.length;

  List<int> _medianColor(List<List<int>> pixels) => [
    for (var channel = 0; channel < 3; channel++)
      _median([for (final c in pixels) c[channel]]),
  ];

  int _median(List<int> values) {
    final sorted = [...values]..sort();
    return sorted[sorted.length ~/ 2];
  }
}
