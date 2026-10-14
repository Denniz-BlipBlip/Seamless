import 'selfie_sampler.dart';

/// Keeps the selfie scan honest: only an unbroken run of good frames counts.
/// Any bad frame (or no face) throws the run away, so every frame sent to the
/// backend was taken under the same steady conditions.
class SelfieSession {
  SelfieSession({this.target = 6}) : assert(target >= 3 && target <= 12);

  /// Frames needed. The backend accepts 3 to 12.
  final int target;

  final List<SelfieSample> _steady = [];
  String _guidance = 'Face the camera in bright, even daylight.';
  bool _lastFrameGood = false;

  String get guidance => _guidance;
  int get collected => _steady.length;
  bool get done => collected >= target;
  bool get lastFrameGood => _lastFrameGood;
  double get progress => (collected / target).clamp(0.0, 1.0);

  void add(SelfieSample sample) {
    if (done) return;
    if (!sample.ready) {
      fail(sample.problems.first);
      return;
    }
    _steady.add(sample);
    _lastFrameGood = true;
    _guidance = done
        ? 'Got it.'
        : 'Hold still… ${_steady.length}/$target';
  }

  void noFace() => fail('Step into the frame.');

  void fail(String message) {
    _steady.clear();
    _lastFrameGood = false;
    _guidance = message;
  }

  /// The frames to send, in the backend's `ColorFrame` format.
  List<Map<String, dynamic>> toFrames() => [
    for (final sample in _steady) sample.toJson(),
  ];
}
