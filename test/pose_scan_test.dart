import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:seamly/services/pose_scan_service.dart';

/// Frame size used by every test. Landmark x/y are in pixels, like ML Kit.
const _size = Size(480, 640);

/// Builds a standing pose. Defaults are a centred, full-body FRONT view:
/// the person's left shoulder sits at the larger x, as when facing the camera.
Pose _pose({
  double leftShoulderX = 300,
  double rightShoulderX = 180,
  double leftHipX = 285,
  double rightHipX = 195,
  double noseY = 77, // 0.12 of frame height
  double ankleY = 576, // 0.90 of frame height
  double likelihood = 0.9,
  double shift = 0,
  Set<PoseLandmarkType> omit = const {},
}) {
  PoseLandmark mark(PoseLandmarkType type, double x, double y) => PoseLandmark(
    type: type,
    x: x + shift,
    y: y,
    z: 0,
    likelihood: likelihood,
  );
  final all = <PoseLandmarkType, PoseLandmark>{
    PoseLandmarkType.nose: mark(PoseLandmarkType.nose, 240, noseY),
    PoseLandmarkType.leftShoulder: mark(
      PoseLandmarkType.leftShoulder,
      leftShoulderX,
      160,
    ),
    PoseLandmarkType.rightShoulder: mark(
      PoseLandmarkType.rightShoulder,
      rightShoulderX,
      160,
    ),
    PoseLandmarkType.leftHip: mark(PoseLandmarkType.leftHip, leftHipX, 330),
    PoseLandmarkType.rightHip: mark(PoseLandmarkType.rightHip, rightHipX, 330),
    PoseLandmarkType.leftKnee: mark(PoseLandmarkType.leftKnee, leftHipX, 450),
    PoseLandmarkType.rightKnee: mark(PoseLandmarkType.rightKnee, rightHipX, 450),
    PoseLandmarkType.leftAnkle: mark(
      PoseLandmarkType.leftAnkle,
      leftHipX,
      ankleY,
    ),
    PoseLandmarkType.rightAnkle: mark(
      PoseLandmarkType.rightAnkle,
      rightHipX,
      ankleY,
    ),
  };
  return Pose(
    landmarks: {
      for (final entry in all.entries)
        if (!omit.contains(entry.key)) entry.key: entry.value,
    },
  );
}

/// Shoulders stacked, as seen from the side.
Pose _sidePose() => _pose(
  leftShoulderX: 250,
  rightShoulderX: 235,
  leftHipX: 245,
  rightHipX: 238,
);

/// Shoulder order swapped: the person's left shoulder is at the smaller x.
Pose _backPose() => _pose(leftShoulderX: 180, rightShoulderX: 300);

/// Between side and front: shoulder width / torso is in the mid-turn band.
Pose _midTurnPose() => _pose(leftShoulderX: 280, rightShoulderX: 200);

/// Feeds the same pose enough frames to fill the stillness window.
PoseFrameResult _settle(PoseScanService service, Pose pose) {
  late PoseFrameResult result;
  for (var i = 0; i < ScanTuning.stillnessWindow; i++) {
    result = service.analyze(pose, _size);
  }
  return result;
}

void main() {
  late PoseScanService service;

  setUp(() {
    // The default detector is only created, never run, in these tests.
    service = PoseScanService();
  });

  group('visibility', () {
    test('no pose asks the user to step into the frame', () {
      final result = service.analyze(null, _size);
      expect(result.personVisible, isFalse);
      expect(result.good, isFalse);
      expect(result.guidance, 'Step into the frame.');
    });

    test('a missing landmark counts as no person', () {
      final result = service.analyze(
        _pose(omit: {PoseLandmarkType.leftAnkle}),
        _size,
      );
      expect(result.personVisible, isFalse);
      expect(result.guidance, 'Step into the frame.');
    });

    test('key points are normalised to 0..1', () {
      final result = service.analyze(_pose(), _size);
      final nose = result.keyPoints['nose']!;
      expect(nose.dx, closeTo(0.5, 1e-9));
      expect(nose.dy, closeTo(0.12, 0.001));
      expect(result.keyPoints.length, 9);
    });
  });

  group('full body and centring', () {
    test('feet cut off at the frame edge are not full body', () {
      final result = service.analyze(_pose(ankleY: 636), _size);
      expect(result.fullBody, isFalse);
      expect(
        result.guidance,
        'Step back until your head and feet are visible.',
      );
    });

    test('too little head room is not full body', () {
      final result = service.analyze(_pose(noseY: 20), _size);
      expect(result.fullBody, isFalse);
    });

    test('a person who is too small in the frame is not full body', () {
      // Head-to-ankle span of 0.40 is under the 0.55 minimum.
      final result = service.analyze(_pose(noseY: 200, ankleY: 456), _size);
      expect(result.fullBody, isFalse);
    });

    test('low landmark confidence is not full body', () {
      final result = service.analyze(_pose(likelihood: 0.2), _size);
      expect(result.fullBody, isFalse);
    });

    test('standing off to one side asks to move to the centre', () {
      final result = service.analyze(_pose(shift: 120), _size);
      expect(result.fullBody, isTrue);
      expect(result.centered, isFalse);
      expect(result.guidance, 'Move to the centre of the frame.');
    });
  });

  group('angle classification', () {
    test('front view is recognised', () {
      final result = service.analyze(_pose(), _size);
      expect(result.detectedAngle, ScanAngle.front);
      expect(result.poseCorrect, isTrue);
    });

    test('back view is recognised from shoulder order', () {
      final result = service.analyze(_backPose(), _size);
      expect(result.detectedAngle, ScanAngle.back);
    });

    test('side view is recognised', () {
      final result = service.analyze(_sidePose(), _size);
      expect(result.detectedAngle, ScanAngle.side);
    });

    test('a mid-turn pose has no angle', () {
      final result = service.analyze(_midTurnPose(), _size);
      expect(result.detectedAngle, isNull);
      expect(result.poseCorrect, isFalse);
    });

    test('the wrong angle gives a turn cue for the target', () {
      expect(
        service.analyze(_backPose(), _size).guidance,
        'Face the camera.',
      );
      service.setTarget(ScanAngle.side);
      expect(
        service.analyze(_pose(), _size).guidance,
        'Turn to your left, side on to the camera.',
      );
      service.setTarget(ScanAngle.back);
      expect(
        service.analyze(_pose(), _size).guidance,
        'Turn around, back to the camera.',
      );
    });

    test('each target accepts its own angle', () {
      service.setTarget(ScanAngle.side);
      expect(service.analyze(_sidePose(), _size).poseCorrect, isTrue);
      service.setTarget(ScanAngle.back);
      expect(service.analyze(_backPose(), _size).poseCorrect, isTrue);
    });
  });

  group('stillness and hold timer', () {
    test('the first frames are not still yet', () {
      final result = service.analyze(_pose(), _size);
      expect(result.still, isFalse);
      expect(result.good, isFalse);
      expect(result.guidance, 'Hold still.');
      expect(result.holdProgress, 0);
    });

    test('a steady pose becomes good once the window is full', () {
      final result = _settle(service, _pose());
      expect(result.still, isTrue);
      expect(result.good, isTrue);
      expect(result.guidance, 'Perfect. Hold still…');
      expect(result.readyToCapture, isFalse);
    });

    test('a moving person is never still', () {
      PoseFrameResult? result;
      for (var i = 0; i < ScanTuning.stillnessWindow * 2; i++) {
        result = service.analyze(_pose(shift: i.isEven ? 0 : 40), _size);
      }
      expect(result!.still, isFalse);
      expect(result.good, isFalse);
      expect(result.holdProgress, 0);
    });

    test('holding the pose for the hold duration allows capture', () async {
      _settle(service, _pose());
      await Future<void>.delayed(
        ScanTuning.holdDuration + const Duration(milliseconds: 150),
      );
      final result = service.analyze(_pose(), _size);
      expect(result.holdProgress, 1.0);
      expect(result.readyToCapture, isTrue);
    });

    test('losing the pose resets the hold timer', () async {
      _settle(service, _pose());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(service.analyze(_pose(), _size).holdProgress, greaterThan(0));
      // Person walks out of the frame.
      service.analyze(null, _size);
      final back = service.analyze(_pose(), _size);
      expect(back.holdProgress, 0);
      expect(back.readyToCapture, isFalse);
    });

    test('changing the target restarts the hold timer', () async {
      _settle(service, _pose());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      service.setTarget(ScanAngle.side);
      expect(service.target, ScanAngle.side);
      final result = service.analyze(_pose(), _size);
      expect(result.holdProgress, 0);
      expect(result.still, isFalse);
    });
  });
}
