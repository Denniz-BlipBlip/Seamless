import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

/// Which side of the body the camera should see.
enum ScanAngle { front, side, back }

/// All thresholds in one place so they can be tuned on a real phone.
abstract final class ScanTuning {
  /// How long a correct, steady pose must be held before auto-capture.
  static const holdDuration = Duration(milliseconds: 1000);

  /// Minimum ML Kit confidence for a landmark to count as visible.
  static const minLikelihood = 0.5;

  /// Landmarks closer than this fraction to the frame edge count as cut off.
  static const edgeMargin = 0.03;

  /// Head-to-ankle span must cover at least this fraction of frame height.
  static const minBodyHeightFraction = 0.55;

  /// Hips must sit within 0.5 +/- this fraction of frame width.
  static const centerBand = 0.18;

  /// Shoulder width / torso height at or below this means side view.
  static const sideRatioMax = 0.38;

  /// Shoulder width / torso height at or above this means front/back view.
  static const wideRatioMin = 0.55;

  /// Max movement (fraction of frame) allowed across the stillness window.
  static const stillnessLimit = 0.012;

  /// Number of recent frames used to judge stillness.
  static const stillnessWindow = 8;
}

/// Outcome of analysing one camera frame.
class PoseFrameResult {
  const PoseFrameResult({
    required this.target,
    required this.detectedAngle,
    required this.personVisible,
    required this.fullBody,
    required this.centered,
    required this.still,
    required this.holdProgress,
    required this.guidance,
    this.keyPoints = const {},
  });

  final ScanAngle target;
  final ScanAngle? detectedAngle;
  final bool personVisible;
  final bool fullBody;
  final bool centered;
  final bool still;

  /// 0..1 progress of the hold timer. 1 means capture now.
  final double holdProgress;

  /// Short on-screen cue for the user.
  final String guidance;

  /// Normalised (0..1) key points, used later for measurements.
  final Map<String, Offset> keyPoints;

  bool get poseCorrect =>
      personVisible && fullBody && centered && detectedAngle == target;

  /// Guide turns green when the pose is right and the user is steady.
  bool get good => poseCorrect && still;

  bool get readyToCapture => holdProgress >= 1;
}

/// On-device pose detection for the guided scan (Android, NV21 stream).
///
/// Feed it camera stream frames. It drops frames while busy, so it is safe
/// to call from the camera image stream callback.
class PoseScanService {
  PoseScanService({PoseDetector? detector})
    : _detector =
          detector ??
          PoseDetector(
            options: PoseDetectorOptions(
              mode: PoseDetectionMode.stream,
              model: PoseDetectionModel.base,
            ),
          );

  /// Landmarks that must all be present for a frame to count.
  static const _needed = {
    'nose': PoseLandmarkType.nose,
    'lShoulder': PoseLandmarkType.leftShoulder,
    'rShoulder': PoseLandmarkType.rightShoulder,
    'lHip': PoseLandmarkType.leftHip,
    'rHip': PoseLandmarkType.rightHip,
    'lKnee': PoseLandmarkType.leftKnee,
    'rKnee': PoseLandmarkType.rightKnee,
    'lAnkle': PoseLandmarkType.leftAnkle,
    'rAnkle': PoseLandmarkType.rightAnkle,
  };

  final PoseDetector _detector;
  final List<Offset> _motion = [];
  DateTime? _goodSince;
  bool _busy = false;
  ScanAngle _target = ScanAngle.front;

  ScanAngle get target => _target;

  /// Switch to the next angle and restart the hold timer.
  void setTarget(ScanAngle angle) {
    _target = angle;
    reset();
  }

  void reset() {
    _motion.clear();
    _goodSince = null;
  }

  Future<void> dispose() => _detector.close();

  /// Analyse one camera frame. Returns null if the frame was skipped.
  Future<PoseFrameResult?> processCameraImage(
    CameraImage image,
    CameraDescription camera,
    DeviceOrientation orientation,
  ) async {
    if (_busy) return null;
    final converted = _toInputImage(image, camera, orientation);
    if (converted == null) return null;
    _busy = true;
    try {
      final poses = await _detector.processImage(converted.image);
      return analyze(poses.isEmpty ? null : poses.first, converted.size);
    } catch (_) {
      return null;
    } finally {
      _busy = false;
    }
  }

  /// Pure analysis step, separated so it can be unit tested with fake poses.
  PoseFrameResult analyze(Pose? pose, Size size) {
    if (pose == null) {
      reset();
      return _result(guidance: 'Step into the frame.');
    }

    final points = <String, PoseLandmark>{};
    for (final entry in _needed.entries) {
      final landmark = pose.landmarks[entry.value];
      if (landmark == null) {
        reset();
        return _result(guidance: 'Step into the frame.');
      }
      points[entry.key] = landmark;
    }

    final keyPoints = {
      for (final e in points.entries)
        e.key: Offset(e.value.x / size.width, e.value.y / size.height),
    };

    // Full body: every landmark confident, inside the frame, and tall enough.
    final confident = points.values.every(
      (p) => p.likelihood >= ScanTuning.minLikelihood,
    );
    final inside = keyPoints.values.every(
      (o) =>
          o.dx > ScanTuning.edgeMargin &&
          o.dx < 1 - ScanTuning.edgeMargin &&
          o.dy > ScanTuning.edgeMargin &&
          o.dy < 1 - ScanTuning.edgeMargin,
    );
    final ankleY = (keyPoints['lAnkle']!.dy + keyPoints['rAnkle']!.dy) / 2;
    final tallEnough =
        ankleY - keyPoints['nose']!.dy >= ScanTuning.minBodyHeightFraction;
    final headRoom = keyPoints['nose']!.dy >= 0.07;
    final fullBody = confident && inside && tallEnough && headRoom;

    final hipMid = Offset(
      (keyPoints['lHip']!.dx + keyPoints['rHip']!.dx) / 2,
      (keyPoints['lHip']!.dy + keyPoints['rHip']!.dy) / 2,
    );
    final shoulderMid = Offset(
      (keyPoints['lShoulder']!.dx + keyPoints['rShoulder']!.dx) / 2,
      (keyPoints['lShoulder']!.dy + keyPoints['rShoulder']!.dy) / 2,
    );
    final centered = (hipMid.dx - 0.5).abs() <= ScanTuning.centerBand;

    final angle = _classifyAngle(
      points['lShoulder']!,
      points['rShoulder']!,
      points['lHip']!,
      points['rHip']!,
    );

    // Stillness over the last few frames.
    _motion.add(
      Offset(
        (hipMid.dx + shoulderMid.dx) / 2,
        (hipMid.dy + shoulderMid.dy) / 2,
      ),
    );
    if (_motion.length > ScanTuning.stillnessWindow) _motion.removeAt(0);
    final still = _isStill();

    final poseCorrect = fullBody && centered && angle == _target;
    final now = DateTime.now();
    if (poseCorrect && still) {
      _goodSince ??= now;
    } else {
      _goodSince = null;
    }
    final progress = _goodSince == null
        ? 0.0
        : (now.difference(_goodSince!).inMilliseconds /
                  ScanTuning.holdDuration.inMilliseconds)
              .clamp(0.0, 1.0);

    final String guidance;
    if (!fullBody) {
      guidance = 'Step back until your head and feet are visible.';
    } else if (!centered) {
      guidance = 'Move to the centre of the frame.';
    } else if (angle != _target) {
      guidance = _turnCue(_target);
    } else if (!still) {
      guidance = 'Hold still.';
    } else {
      guidance = 'Perfect. Hold still…';
    }

    return PoseFrameResult(
      target: _target,
      detectedAngle: angle,
      personVisible: true,
      fullBody: fullBody,
      centered: centered,
      still: still,
      holdProgress: progress,
      guidance: guidance,
      keyPoints: keyPoints,
    );
  }

  PoseFrameResult _result({required String guidance}) => PoseFrameResult(
    target: _target,
    detectedAngle: null,
    personVisible: false,
    fullBody: false,
    centered: false,
    still: false,
    holdProgress: 0,
    guidance: guidance,
  );

  bool _isStill() {
    if (_motion.length < ScanTuning.stillnessWindow) return false;
    final meanX =
        _motion.map((o) => o.dx).reduce((a, b) => a + b) / _motion.length;
    final meanY =
        _motion.map((o) => o.dy).reduce((a, b) => a + b) / _motion.length;
    final spread = _motion
        .map((o) {
          final dx = o.dx - meanX;
          final dy = o.dy - meanY;
          return math.sqrt(dx * dx + dy * dy);
        })
        .fold<double>(0.0, math.max);
    return spread <= ScanTuning.stillnessLimit;
  }

  /// Front/back: shoulders wide. Side: shoulders stacked.
  ///
  /// Front vs back uses the left/right order of the shoulders only: the
  /// person's left shoulder appears on the image right when they face the
  /// camera, and on the image left when they face away. ML Kit's landmark
  /// `likelihood` means "in frame", not "visible", so the nose stays
  /// confident from behind and is no use as a second vote.
  ScanAngle? _classifyAngle(
    PoseLandmark ls,
    PoseLandmark rs,
    PoseLandmark lh,
    PoseLandmark rh,
  ) {
    final shoulderWidth = (ls.x - rs.x).abs();
    final dx = (ls.x + rs.x) / 2 - (lh.x + rh.x) / 2;
    final dy = (ls.y + rs.y) / 2 - (lh.y + rh.y) / 2;
    final torso = math.sqrt(dx * dx + dy * dy);
    if (torso <= 0) return null;
    final ratio = shoulderWidth / torso;
    if (ratio <= ScanTuning.sideRatioMax) return ScanAngle.side;
    if (ratio < ScanTuning.wideRatioMin) return null; // mid-turn
    return ls.x > rs.x ? ScanAngle.front : ScanAngle.back;
  }

  static String _turnCue(ScanAngle target) => switch (target) {
    ScanAngle.front => 'Face the camera.',
    ScanAngle.side => 'Turn to your left, side on to the camera.',
    ScanAngle.back => 'Turn around, back to the camera.',
  };

  static const _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  /// Android NV21 camera frame -> ML Kit input, plus the rotated frame size
  /// (ML Kit returns coordinates in the rotated image space).
  ({InputImage image, Size size})? _toInputImage(
    CameraImage image,
    CameraDescription camera,
    DeviceOrientation orientation,
  ) {
    if (!Platform.isAndroid) return null;
    final compensation = _orientations[orientation];
    if (compensation == null) return null;
    final sensor = camera.sensorOrientation;
    final degrees = camera.lensDirection == CameraLensDirection.front
        ? (sensor + compensation) % 360
        : (sensor - compensation + 360) % 360;
    final rotation = InputImageRotationValue.fromRawValue(degrees);
    if (rotation == null) return null;
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format != InputImageFormat.nv21 || image.planes.length != 1) {
      return null;
    }
    final plane = image.planes.first;
    final raw = Size(image.width.toDouble(), image.height.toDouble());
    final rotated = (degrees == 90 || degrees == 270)
        ? Size(raw.height, raw.width)
        : raw;
    return (
      image: InputImage.fromBytes(
        bytes: plane.bytes,
        metadata: InputImageMetadata(
          size: raw,
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: plane.bytesPerRow,
        ),
      ),
      size: rotated,
    );
  }
}
