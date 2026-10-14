import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/pose_scan_service.dart';

/// One captured angle: the photo plus the body points seen at that moment.
class ScanShot {
  const ScanShot({
    required this.angle,
    required this.jpegBytes,
    required this.keyPoints,
  });

  final ScanAngle angle;
  final Uint8List jpegBytes;

  /// Normalised (0..1) key points from the live pose frame.
  final Map<String, Offset> keyPoints;
}

/// Hands-free scan: the user stands back, the phone watches the pose, and
/// each photo is taken automatically once the pose is right and steady.
/// Order: front, side, back. The back photo can be skipped.
class GuidedScanScreen extends StatefulWidget {
  const GuidedScanScreen({
    super.key,
    required this.onCompleted,
    required this.onCancel,
    this.service,
  });

  final ValueChanged<Map<ScanAngle, ScanShot>> onCompleted;
  final VoidCallback onCancel;
  final PoseScanService? service;

  @override
  State<GuidedScanScreen> createState() => _GuidedScanScreenState();
}

class _GuidedScanScreenState extends State<GuidedScanScreen>
    with WidgetsBindingObserver {
  static const _order = [ScanAngle.front, ScanAngle.side, ScanAngle.back];
  static const _frameGap = Duration(milliseconds: 120);
  static const _cooldown = Duration(seconds: 2);

  late final PoseScanService _service = widget.service ?? PoseScanService();
  final Map<ScanAngle, ScanShot> _shots = {};

  CameraController? _controller;
  CameraDescription? _description;
  CameraLensDirection _lens = CameraLensDirection.back;
  PoseFrameResult? _result;
  String? _error;
  String _transition = '';
  int _index = 0;
  bool _starting = false;
  bool _capturing = false;
  bool _finished = false;
  bool _disposed = false;
  bool _flash = false;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _cooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _service.setTarget(_order.first);
    unawaited(_start());
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_closeCamera());
    if (widget.service == null) unawaited(_service.dispose());
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
        (c) => c.lensDirection == _lens,
        orElse: () => cameras.first,
      );
      pending = CameraController(
        description,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await pending.initialize();
      if (!mounted || _disposed) return;
      await pending.startImageStream(_onFrame);
      _controller = pending;
      _description = description;
      pending = null;
      _service.reset();
    } on Exception {
      if (mounted) {
        setState(
          () => _error =
              'Allow camera access to start the scan, then tap Try again.',
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
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } on Exception {
      // Best effort: the controller is disposed next anyway.
    }
    await controller.dispose();
  }

  Future<void> _switchCamera() async {
    if (_capturing || _starting) return;
    _lens = _lens == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    await _closeCamera();
    if (mounted) await _start();
  }

  void _onFrame(CameraImage image) {
    if (_capturing || _finished || _disposed) return;
    final now = DateTime.now();
    if (now.difference(_lastFrame) < _frameGap) return;
    _lastFrame = now;
    final description = _description;
    if (description == null) return;
    unawaited(_handleFrame(image, description));
  }

  Future<void> _handleFrame(
    CameraImage image,
    CameraDescription description,
  ) async {
    final result = await _service.processCameraImage(
      image,
      description,
      DeviceOrientation.portraitUp,
    );
    if (result == null || !mounted || _capturing || _finished) return;
    setState(() => _result = result);
    if (result.readyToCapture && DateTime.now().isAfter(_cooldownUntil)) {
      await _capture(result);
    }
  }

  Future<void> _capture(PoseFrameResult result) async {
    if (_capturing) return;
    _capturing = true;
    final angle = _order[_index];
    final controller = _controller;
    try {
      if (controller == null) return;
      await controller.stopImageStream();
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      _shots[angle] = ScanShot(
        angle: angle,
        jpegBytes: bytes,
        keyPoints: Map.of(result.keyPoints),
      );
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.click);
      _flashOnce();

      if (_index == _order.length - 1) {
        _finished = true;
        await _closeCamera();
        if (mounted) widget.onCompleted(Map.of(_shots));
        return;
      }
      _index++;
      _transition = switch (_order[_index]) {
        ScanAngle.side => 'Front done ✓\nNow turn to your left.',
        ScanAngle.back => 'Side done ✓\nNow turn around.',
        ScanAngle.front => 'Face the camera.',
      };
      _service.setTarget(_order[_index]);
      _cooldownUntil = DateTime.now().add(_cooldown);
      await controller.startImageStream(_onFrame);
    } on Exception {
      if (mounted) {
        setState(() => _error = 'The photo could not be taken. Trying again…');
      }
      try {
        if (controller != null && !controller.value.isStreamingImages) {
          await controller.startImageStream(_onFrame);
        }
        if (mounted) setState(() => _error = null);
      } on Exception {
        // The Try again button handles a dead camera.
      }
    } finally {
      _capturing = false;
      if (mounted) setState(() {});
    }
  }

  /// Finish with the front and side photos only. Offered on the last step so
  /// a back photo that is never recognised cannot block the whole scan.
  Future<void> _skipBack() async {
    if (_capturing || _finished || _shots.length < 2) return;
    _finished = true;
    await _closeCamera();
    if (mounted) widget.onCompleted(Map.of(_shots));
  }

  void _flashOnce() {
    if (!mounted) return;
    setState(() => _flash = true);
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _flash = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;
    final result = _result;
    final cooling = DateTime.now().isBefore(_cooldownUntil);
    final good = !cooling && (result?.good ?? false);
    final progress = cooling ? 0.0 : (result?.holdProgress ?? 0.0);
    final onBackStep = _index == _order.length - 1;
    final guidance =
        _error ??
        (cooling
            ? _transition
            : (result?.guidance ?? 'Stand back so the camera can see you.'));

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
              child: CustomPaint(painter: _GuidePainter(good: good)),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                children: [
                  Row(
                    children: [
                      _RoundButton(
                        tooltip: 'Cancel scan',
                        icon: Icons.close,
                        onPressed: widget.onCancel,
                      ),
                      const Spacer(),
                      _StepChips(
                        order: _order,
                        current: _index,
                        done: _shots.keys.toSet(),
                      ),
                      const Spacer(),
                      _RoundButton(
                        tooltip: 'Switch camera',
                        icon: Icons.cameraswitch_outlined,
                        onPressed: _capturing || _starting
                            ? null
                            : _switchCamera,
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
                        guidance,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
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
                    if (progress > 0)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 12,
                          color: const Color(0xFF4ADE80),
                          backgroundColor: Colors.white24,
                        ),
                      ),
                    if (onBackStep && ready && !_capturing)
                      TextButton(
                        key: const ValueKey('skip-back-photo'),
                        onPressed: _skipBack,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          minimumSize: const Size(48, 48),
                        ),
                        child: const Text('Skip back photo'),
                      ),
                    const SizedBox(height: 6),
                    const Text(
                      'Lean the phone upright 2–3 m away. The photo is taken automatically.',
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
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _flash ? 0.85 : 0,
              duration: const Duration(milliseconds: 120),
              child: const ColoredBox(color: Colors.white),
            ),
          ),
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

class _GuidePainter extends CustomPainter {
  const _GuidePainter({required this.good});

  final bool good;

  @override
  void paint(Canvas canvas, Size size) {
    final color = good
        ? const Color(0xFF4ADE80)
        : Colors.white.withValues(alpha: 0.6);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = good ? 5 : 3
      ..color = color;
    final width = size.width * 0.62;
    final height = size.height * 0.80;
    final left = (size.width - width) / 2;
    final top = size.height * 0.15;
    final frame = Rect.fromLTWH(left, top, width, height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(frame, const Radius.circular(36)),
      paint,
    );
    final headRadius = width * 0.15;
    canvas.drawCircle(
      Offset(frame.center.dx, top + headRadius + height * 0.02),
      headRadius,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _GuidePainter oldDelegate) =>
      oldDelegate.good != good;
}

class _StepChips extends StatelessWidget {
  const _StepChips({
    required this.order,
    required this.current,
    required this.done,
  });

  final List<ScanAngle> order;
  final int current;
  final Set<ScanAngle> done;

  static String _label(ScanAngle angle) => switch (angle) {
    ScanAngle.front => 'Front',
    ScanAngle.side => 'Side',
    ScanAngle.back => 'Back',
  };

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      children: [
        for (var i = 0; i < order.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: done.contains(order[i])
                  ? const Color(0xFF16A34A)
                  : i == current
                  ? Colors.white
                  : Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (done.contains(order[i]))
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(Icons.check, size: 14, color: Colors.white),
                  ),
                Text(
                  _label(order[i]),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: i == current && !done.contains(order[i])
                        ? Colors.black
                        : Colors.white,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon),
    style: IconButton.styleFrom(
      minimumSize: const Size(48, 48),
      foregroundColor: Colors.white,
      disabledForegroundColor: Colors.white30,
      backgroundColor: Colors.black38,
    ),
  );
}
