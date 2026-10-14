import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

import '../services/selfie_sampler.dart';
import '../services/selfie_session.dart';

/// Front-camera selfie scan for face colors.
///
/// Takes a photo every moment, finds the face on the phone, samples colors
/// from it, and keeps only an unbroken run of good frames. The photos never
/// leave the phone: [onCompleted] receives only sampled color numbers, in the
/// backend's frame format. Needs a real device (camera + ML Kit).
class SelfieScanScreen extends StatefulWidget {
  const SelfieScanScreen({
    super.key,
    required this.onCompleted,
    required this.onCancel,
    this.sampler = const SelfieSampler(),
  });

  final ValueChanged<List<Map<String, dynamic>>> onCompleted;
  final VoidCallback onCancel;
  final SelfieSampler sampler;

  @override
  State<SelfieScanScreen> createState() => _SelfieScanScreenState();
}

class _SelfieScanScreenState extends State<SelfieScanScreen>
    with WidgetsBindingObserver {
  static const _pause = Duration(milliseconds: 250);
  static const _exposureSettle = Duration(milliseconds: 1500);

  final SelfieSession _session = SelfieSession();
  late final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableContours: true,
      enableLandmarks: true,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );

  CameraController? _controller;
  String? _error;
  bool _starting = false;
  bool _looping = false;
  bool _finished = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    unawaited(_start());
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_closeCamera());
    unawaited(_detector.close());
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_finished) return;
    if (state == AppLifecycleState.inactive) {
      unawaited(_closeCamera());
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      unawaited(_start());
    }
  }

  Future<void> _start() async {
    if (_starting || _finished || _disposed) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    CameraController? pending;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw CameraException('none', 'No camera found');
      final description = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      pending = CameraController(
        description,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await pending.initialize();
      if (!mounted || _disposed) return;
      try {
        await pending.setFlashMode(FlashMode.off);
      } on Exception {
        // Some front cameras have no flash control.
      }
      _controller = pending;
      pending = null;
      unawaited(_run());
    } on Exception {
      if (mounted) {
        setState(
          () => _error =
              'Allow camera access to start the selfie scan, then tap Try again.',
        );
      }
    } finally {
      await pending?.dispose();
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _closeCamera() async {
    final controller = _controller;
    _controller = null;
    await controller?.dispose();
  }

  /// Lets auto-exposure settle, locks it so every frame is lit the same way,
  /// then keeps taking and checking photos until enough good ones are in.
  Future<void> _run() async {
    if (_looping) return;
    _looping = true;
    try {
      await Future<void>.delayed(_exposureSettle);
      final first = _controller;
      if (first != null) {
        try {
          await first.setExposureMode(ExposureMode.locked);
        } on Exception {
          // Not every camera can lock exposure; carry on without it.
        }
      }
      while (mounted && !_disposed && !_finished) {
        final controller = _controller;
        if (controller == null || !controller.value.isInitialized) break;
        try {
          await _step(controller);
        } on Exception {
          _session.fail('Could not read that photo. Hold still…');
        }
        if (!mounted || _disposed || _finished) return;
        setState(() {});
        if (_session.done) {
          _finished = true;
          await _closeCamera();
          if (mounted) widget.onCompleted(_session.toFrames());
          return;
        }
        await Future<void>.delayed(_pause);
      }
    } finally {
      _looping = false;
    }
  }

  Future<void> _step(CameraController controller) async {
    final file = await controller.takePicture();
    final bytes = await file.readAsBytes();
    unawaited(_deleteQuietly(file.path));

    final prepared = await Isolate.run(() => _prepare(bytes));
    if (prepared == null) {
      _session.fail('Could not read that photo. Hold still…');
      return;
    }
    final image = img.decodeJpg(prepared);
    final faces = await _detectFaces(prepared);
    if (image == null || faces.isEmpty) {
      _session.noFace();
      return;
    }
    final face = faces.reduce(
      (a, b) =>
          a.boundingBox.width * a.boundingBox.height >=
              b.boundingBox.width * b.boundingBox.height
          ? a
          : b,
    );
    final geometry = _geometry(face);
    if (geometry == null) {
      _session.noFace();
      return;
    }
    try {
      _session.add(widget.sampler.sample(image, geometry));
    } on SelfieSampleException catch (error) {
      _session.fail(error.message);
    }
  }

  Future<List<Face>> _detectFaces(Uint8List jpeg) async {
    final directory = await Directory.systemTemp.createTemp('seamly-selfie');
    try {
      final path = '${directory.path}/face.jpg';
      await File(path).writeAsBytes(jpeg, flush: true);
      return await _detector.processImage(InputImage.fromFilePath(path));
    } finally {
      try {
        await directory.delete(recursive: true);
      } on Exception {
        // Best-effort temp cleanup.
      }
    }
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } on Exception {
      // The camera plugin cleans its cache anyway.
    }
  }

  FaceGeometry? _geometry(Face face) {
    Offset? landmark(FaceLandmarkType type) {
      final position = face.landmarks[type]?.position;
      return position == null
          ? null
          : Offset(position.x.toDouble(), position.y.toDouble());
    }

    List<Offset> contour(FaceContourType type) {
      final points = face.contours[type]?.points;
      if (points == null) return const [];
      return [for (final p in points) Offset(p.x.toDouble(), p.y.toDouble())];
    }

    final leftEye = landmark(FaceLandmarkType.leftEye);
    final rightEye = landmark(FaceLandmarkType.rightEye);
    final mouthLeft = landmark(FaceLandmarkType.leftMouth);
    final mouthRight = landmark(FaceLandmarkType.rightMouth);
    if (leftEye == null ||
        rightEye == null ||
        mouthLeft == null ||
        mouthRight == null) {
      return null;
    }
    return FaceGeometry(
      faceBox: face.boundingBox,
      leftEye: leftEye,
      rightEye: rightEye,
      mouthLeft: mouthLeft,
      mouthRight: mouthRight,
      leftEyeContour: contour(FaceContourType.leftEye),
      rightEyeContour: contour(FaceContourType.rightEye),
      headYawDegrees: face.headEulerAngleY ?? 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;
    final good = _session.lastFrameGood;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (ready)
            _CoverPreview(controller: controller)
          else
            const ColoredBox(color: Color(0xFF151515)),
          if (ready)
            IgnorePointer(
              child: CustomPaint(painter: _FaceGuidePainter(good: good)),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        key: const ValueKey('selfie-cancel'),
                        tooltip: 'Cancel',
                        onPressed: widget.onCancel,
                        icon: const Icon(Icons.close),
                        style: IconButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          foregroundColor: Colors.white,
                          backgroundColor: Colors.black38,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: good
                            ? const Color(0xFF16A34A)
                            : Colors.black.withValues(alpha: 0.62),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        _error ?? _session.guidance,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          height: 1.25,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (_error != null && !_starting && !ready)
                    FilledButton(
                      onPressed: _start,
                      child: const Text('Try again'),
                    )
                  else ...[
                    if (_session.collected > 0)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: _session.progress,
                          minHeight: 12,
                          color: const Color(0xFF4ADE80),
                          backgroundColor: Colors.white24,
                        ),
                      ),
                    const SizedBox(height: 8),
                    const Text(
                      'Use daylight, no filter. Look straight ahead with your eyes open. Photos stay on your phone; only color numbers are sent.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_starting && !ready)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
        ],
      ),
    );
  }
}

class _CoverPreview extends StatelessWidget {
  const _CoverPreview({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    // The screen is locked to portrait, so the preview ratio is inverted.
    final ratio = 1 / controller.value.aspectRatio;
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: ratio * 1000,
          height: 1000,
          child: CameraPreview(controller),
        ),
      ),
    );
  }
}

class _FaceGuidePainter extends CustomPainter {
  const _FaceGuidePainter({required this.good});

  final bool good;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = good ? 5 : 3
      ..color = good
          ? const Color(0xFF4ADE80)
          : Colors.white.withValues(alpha: 0.6);
    final width = size.width * 0.70;
    final height = size.height * 0.46;
    canvas.drawOval(
      Rect.fromLTWH((size.width - width) / 2, size.height * 0.22, width, height),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _FaceGuidePainter oldDelegate) =>
      oldDelegate.good != good;
}

/// Runs in a background isolate: decode, apply EXIF rotation, shrink, and
/// re-encode at high quality so the face detector and the sampler see the
/// same upright pixels.
Uint8List? _prepare(Uint8List jpeg) {
  final decoded = img.decodeImage(jpeg);
  if (decoded == null) return null;
  var image = img.bakeOrientation(decoded);
  if (image.height > 720) {
    image = img.copyResize(
      image,
      height: 720,
      interpolation: img.Interpolation.average,
    );
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 95));
}
