import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:qr_origin/config/app_config.dart';
import 'package:qr_origin/controllers/scan_controller.dart';
import 'package:qr_origin/models/scan_state.dart';
import 'package:qr_origin/models/pose_frame.dart';
import 'package:qr_origin/models/qr_detection.dart';
import 'package:qr_origin/services/ar_service_interface.dart';
import 'package:qr_origin/services/camera_ar_service.dart';
import 'package:qr_origin/services/mock_ar_service.dart';
import 'package:qr_origin/widgets/angle_indicator.dart';
import 'package:qr_origin/widgets/axes_overlay.dart';
import 'package:qr_origin/widgets/debug_overlay.dart';
import 'package:qr_origin/widgets/progress_ring.dart';
import 'package:qr_origin/widgets/stability_bar.dart';
import 'package:qr_origin/widgets/verification_dialog.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  late final ArServiceInterface _arService;
  late final ScanController _controller;
  bool _showDebug = AppConfig.showDebugByDefault;
  bool _dialogShown = false;
  bool _initialized = false;
  String? _initError;

  // Live tracking after origin lock
  StreamSubscription<PoseFrame>? _livePoseSub;
  PoseFrame? _currentPose;
  StreamSubscription? _detectionSub;
  QrDetection? _lastDetection;

  @override
  void initState() {
    super.initState();
    _initServices();
  }

  Future<void> _initServices() async {
    try {
      if (AppConfig.useMockAr) {
        final scenario = switch (AppConfig.mockScenario) {
          'normal' => MockScenario.normal,
          'obliqueApproach' => MockScenario.obliqueApproach,
          'trackingGlitch' => MockScenario.trackingGlitch,
          'gradualDrift' => MockScenario.gradualDrift,
          'realistic' => MockScenario.realistic,
          _ => MockScenario.realistic,
        };
        _arService = MockArService(scenario: scenario);
      } else {
        _arService = CameraArService(qrPhysicalSize: AppConfig.qrPhysicalSizeM);
      }

      _controller = ScanController(arService: _arService);
      _controller.addListener(_onStateChanged);
      await _controller.startSession();

      // Subscribe to detection stream for realtime axes overlay
      if (_arService is CameraArService) {
        _detectionSub = (_arService as CameraArService).detectionStream.listen((det) {
          if (mounted) setState(() => _lastDetection = det);
        });
      }

      setState(() => _initialized = true);
    } catch (e) {
      setState(() => _initError = e.toString());
    }
  }

  void _onStateChanged() {
    if (!mounted) return;
    setState(() {});
    if (_controller.state == ScanState.verifying && !_dialogShown) {
      _dialogShown = true;
      _showVerificationDialog();
    }
  }

  void _showVerificationDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => VerificationDialog(
        confidence: _controller.confidence,
        positionStdDev: _controller.averagingResult?.positionStdDev ?? 0,
        rotationSpread: _controller.averagingResult?.rotationSpreadDeg ?? 0,
        gravityResult: _controller.gravityResult,
        report: _controller.verificationReport,
        previousComparison: _controller.previousComparison,
        onConfirm: () {
          Navigator.of(ctx).pop();
          _dialogShown = false;
          _controller.confirmOrigin();
        },
        onReject: () {
          Navigator.of(ctx).pop();
          _dialogShown = false;
          _controller.rejectOrigin();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Loading state
    if (!_initialized && _initError == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Colors.blue),
              SizedBox(height: 16),
              Text('Initializing camera...',
                  style: TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      );
    }

    // Error state
    if (_initError != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error, color: Colors.red, size: 48),
                const SizedBox(height: 16),
                Text(
                  'Failed to initialize:\n$_initError',
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _initError = null;
                      _initialized = false;
                    });
                    _initServices();
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          // Camera preview (real) or black background (mock)
          _buildCameraPreview(),

          // Status bar at top
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 16,
            right: 16,
            child: _buildStatusBar(),
          ),

          // Angle indicator (center)
          if (_controller.state == ScanState.scanning ||
              _controller.state == ScanState.collecting)
            Center(
              child: AngleIndicator(
                angleResult: _controller.lastAngleResult,
                isCollecting: _controller.state == ScanState.collecting,
              ),
            ),

          // Stability bar during collection
          if (_controller.state == ScanState.collecting)
            Positioned(
              bottom: 160,
              left: 32,
              right: 32,
              child: StabilityBar(
                positionStdDev: _controller.positionStdDev,
                spatialSpread: _controller.spatialSpread,
              ),
            ),

          // Progress ring during collection
          if (_controller.state == ScanState.collecting)
            Positioned(
              bottom: 100,
              left: 0,
              right: 0,
              child: Center(
                child: ProgressRing(progress: _controller.progress),
              ),
            ),

          // Computing indicator
          if (_controller.state == ScanState.averaging)
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.purple),
                  SizedBox(height: 16),
                  Text('Computing origin...',
                      style: TextStyle(color: Colors.white70, fontSize: 16)),
                ],
              ),
            ),

          // Locked indicator
          if (_controller.state == ScanState.locked)
            Center(
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle,
                        color: Colors.white, size: 64),
                    const SizedBox(height: 12),
                    const Text('Origin Locked',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(
                      'Confidence: ${(_controller.confidence * 100).toInt()}%\n'
                      'σ = ${((_controller.averagingResult?.positionStdDev ?? 0) * 1000).toStringAsFixed(2)}mm',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
            ),

          // 3D Axes overlay — show whenever QR is detected
          if (_lastDetection != null)
            Positioned.fill(
              child: AxesOverlay(
                detection: _lastDetection,
                isLocked: _controller.state == ScanState.locked,
              ),
            ),

          // Debug overlay
          if (_showDebug)
            Positioned(
              top: MediaQuery.of(context).padding.top + 80,
              right: 8,
              bottom: 80,
              child: SingleChildScrollView(
                child: DebugOverlay(controller: _controller),
              ),
            ),

          // Bottom controls
          Positioned(
            bottom: 32,
            left: 16,
            right: 16,
            child: _buildBottomControls(),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraPreview() {
    // If using real camera service, show camera preview
    if (!AppConfig.useMockAr && _arService is CameraArService) {
      final camService = _arService as CameraArService;
      final controller = camService.cameraController;
      if (controller != null && controller.value.isInitialized) {
        return SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: controller.value.previewSize!.height,
              height: controller.value.previewSize!.width,
              child: CameraPreview(controller),
            ),
          ),
        );
      }
    }

    // Fallback: black background
    return Container(color: Colors.black);
  }

  Widget _buildStatusBar() {
    final color = switch (_controller.state) {
      ScanState.scanning => Colors.orange,
      ScanState.collecting => Colors.blue,
      ScanState.averaging => Colors.purple,
      ScanState.verifying => Colors.amber,
      ScanState.locked => Colors.green,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: 2),
      ),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _controller.statusMessage,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _controller.state.name.toUpperCase(),
              style: TextStyle(
                  color: color, fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          onPressed: () => setState(() => _showDebug = !_showDebug),
          icon: Icon(Icons.bug_report,
              color: _showDebug ? Colors.amber : Colors.white54, size: 28),
        ),
        if (_controller.state == ScanState.collecting)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(16)),
            child: Text(
              '${_controller.acceptedFrames} / 30 frames',
              style: const TextStyle(
                  color: Colors.white70, fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        if (_controller.state != ScanState.scanning)
          ElevatedButton.icon(
            onPressed: () {
              _dialogShown = false;
              _controller.reset();
            },
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Reset'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _livePoseSub?.cancel();
    _detectionSub?.cancel();
    if (_initialized) {
      _controller.removeListener(_onStateChanged);
      _controller.dispose();
    }
    super.dispose();
  }
}
