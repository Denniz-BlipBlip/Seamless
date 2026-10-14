import 'package:flutter_test/flutter_test.dart';
import 'package:seamly/services/selfie_sampler.dart';
import 'package:seamly/services/selfie_session.dart';

SelfieSample _sample({List<String> problems = const []}) => SelfieSample(
  skin: const [
    [198, 150, 125],
  ],
  white: const [
    [235, 235, 232],
  ],
  hair: const [40, 30, 25],
  eye: const [70, 45, 30],
  problems: problems,
);

void main() {
  test('collects an unbroken run of good frames and finishes', () {
    final session = SelfieSession(target: 4);
    for (var i = 1; i <= 3; i++) {
      session.add(_sample());
      expect(session.done, isFalse);
      expect(session.guidance, 'Hold still… $i/4');
      expect(session.lastFrameGood, isTrue);
    }
    session.add(_sample());
    expect(session.done, isTrue);
    expect(session.progress, 1.0);
    final frames = session.toFrames();
    expect(frames, hasLength(4));
    expect(frames.first.keys, containsAll(['skin_rgb', 'white_rgb']));
  });

  test('a bad frame throws the whole run away and shows the problem', () {
    final session = SelfieSession(target: 4);
    session.add(_sample());
    session.add(_sample());
    session.add(_sample(problems: const ['Too dark. Move to bright light.']));
    expect(session.collected, 0);
    expect(session.guidance, 'Too dark. Move to bright light.');
    expect(session.lastFrameGood, isFalse);
    expect(session.toFrames(), isEmpty);
  });

  test('no face resets progress', () {
    final session = SelfieSession(target: 3)..add(_sample());
    session.noFace();
    expect(session.collected, 0);
    expect(session.guidance, 'Step into the frame.');
  });

  test('frames added after finishing are ignored', () {
    final session = SelfieSession(target: 3);
    for (var i = 0; i < 5; i++) {
      session.add(_sample());
    }
    expect(session.collected, 3);
  });
}
