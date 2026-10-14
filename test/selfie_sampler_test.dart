import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:seamly/services/selfie_sampler.dart';

// Synthetic 300 x 400 selfie: grey background, hair above a skin-colored
// face, two eyes with white sclera and a dark iris.
const _w = 300;
const _h = 400;
const _skin = [198, 150, 125];
const _hair = [40, 30, 25];
const _sclera = [235, 235, 232];
const _iris = [70, 45, 30];

void _rect(img.Image im, int x1, int y1, int x2, int y2, List<int> c) {
  for (var y = y1; y < y2; y++) {
    for (var x = x1; x < x2; x++) {
      im.setPixelRgb(x, y, c[0], c[1], c[2]);
    }
  }
}

List<int> _plus(List<int> c, int boost) => [
  for (final v in c) (v + boost).clamp(0, 255),
];

img.Image _photo({
  List<int> skin = _skin,
  bool eyesOpen = true,
  int leftCheekBoost = 0,
}) {
  final im = img.Image(width: _w, height: _h);
  _rect(im, 0, 0, _w, _h, const [120, 120, 120]);
  _rect(im, 110, 60, 190, 100, _hair);
  _rect(im, 75, 100, 225, 300, skin);
  if (leftCheekBoost != 0) {
    _rect(im, 108, 202, 132, 226, _plus(skin, leftCheekBoost));
  }
  for (final x in const [110, 170]) {
    if (eyesOpen) {
      _rect(im, x, 166, x + 20, 174, _sclera);
      _rect(im, x + 7, 166, x + 13, 174, _iris);
    }
  }
  return im;
}

List<Offset> _eyeBox(double x) => [
  Offset(x, 166),
  Offset(x + 20, 166),
  Offset(x + 20, 174),
  Offset(x, 174),
];

FaceGeometry _face({
  Rect faceBox = const Rect.fromLTWH(75, 100, 150, 200),
  double yaw = 0,
}) => FaceGeometry(
  faceBox: faceBox,
  leftEye: const Offset(120, 170),
  rightEye: const Offset(180, 170),
  mouthLeft: const Offset(125, 250),
  mouthRight: const Offset(175, 250),
  leftEyeContour: _eyeBox(110),
  rightEyeContour: _eyeBox(170),
  headYawDegrees: yaw,
);

bool _has(SelfieSample s, String text) =>
    s.problems.any((p) => p.contains(text));

void main() {
  const sampler = SelfieSampler();

  test('a good selfie is ready and yields all four color groups', () {
    final sample = sampler.sample(_photo(), _face());
    expect(sample.problems, isEmpty);
    expect(sample.ready, isTrue);
    expect(sample.skin.length, inInclusiveRange(150, 300));
    expect(sample.skin.first, _skin);
    expect(sample.white, isNotNull);
    expect(sample.white!.first, _sclera);
    expect(sample.hair, _hair);
    expect(sample.eye, _iris);
  });

  test('toJson matches the backend frame keys and sends no photo', () {
    final json = sampler.sample(_photo(), _face()).toJson();
    expect(
      json.keys,
      containsAll(['skin_rgb', 'white_rgb', 'hair_rgb', 'eye_rgb']),
    );
    expect(json.containsKey('image_base64'), isFalse);
  });

  test('a dark photo is rejected', () {
    final sample = sampler.sample(_photo(skin: const [40, 30, 25]), _face());
    expect(sample.ready, isFalse);
    expect(_has(sample, 'dark'), isTrue);
  });

  test('uneven side lighting is rejected', () {
    final sample = sampler.sample(_photo(leftCheekBoost: 60), _face());
    expect(_has(sample, 'One side'), isTrue);
  });

  test('closed eyes give no white reference', () {
    final sample = sampler.sample(_photo(eyesOpen: false), _face());
    expect(sample.white, isNull);
    expect(_has(sample, 'eyes'), isTrue);
  });

  test('a turned head is rejected', () {
    final sample = sampler.sample(_photo(), _face(yaw: 30));
    expect(_has(sample, 'straight'), isTrue);
  });

  test('a face that is too small asks to move closer', () {
    final sample = sampler.sample(
      _photo(),
      _face(faceBox: const Rect.fromLTWH(120, 100, 60, 200)),
    );
    expect(_has(sample, 'closer'), isTrue);
  });

  test('hair is skipped when it would fall outside the photo', () {
    final sample = sampler.sample(
      _photo(),
      _face(faceBox: const Rect.fromLTWH(75, 20, 150, 280)),
    );
    expect(sample.hair, isNull);
    expect(sample.ready, isTrue);
  });

  test('cheeks outside the photo throw', () {
    const off = FaceGeometry(
      faceBox: Rect.fromLTWH(-200, 100, 150, 200),
      leftEye: Offset(-120, 170),
      rightEye: Offset(-60, 170),
      mouthLeft: Offset(-115, 250),
      mouthRight: Offset(-65, 250),
    );
    expect(
      () => sampler.sample(_photo(), off),
      throwsA(isA<SelfieSampleException>()),
    );
  });
}
