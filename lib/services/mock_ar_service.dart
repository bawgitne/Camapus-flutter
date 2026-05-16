import 'dart:async';
import 'dart:math';
import 'package:vector_math/vector_math_64.dart';
import 'package:qr_origin/models/pose_frame.dart';
import 'package:qr_origin/services/ar_service_interface.dart';

/// Mock AR service for testing the full pipeline on any device
/// without requiring ARCore hardware.
///
/// Simulates realistic scenarios:
/// - Normal scan (good angle, low noise)
/// - Oblique approach (bad angle, should be rejected)
/// - Tracking glitches (sudden jumps, should be caught by frame collector)
/// - Gradual drift (tests spatial clustering)
class MockArService implements ArServiceInterface {
  final StreamController<PoseFrame> _poseController =
      StreamController<PoseFrame>.broadcast();

  Timer? _frameTimer;
  final Random _rng = Random(42);

  // Simulated QR position (fixed in "world" space)
  final Vector3 _qrPosition = Vector3(0.0, -0.5, -1.0);
  final Quaternion _qrRotation = Quaternion.identity();

  // Simulation scenario
  final MockScenario scenario;

  @override
  Vector3? lastGravityVector = Vector3(0.0, -9.81, 0.0);
  @override
  String? detectedQrId = 'mock_qr_001';

  @override
  Stream<PoseFrame> get poseFrameStream => _poseController.stream;

  MockArService({this.scenario = MockScenario.normal});

  @override
  Future<void> initialize() async {
    await Future.delayed(const Duration(milliseconds: 300));
    _startSimulation();
  }

  void _startSimulation() {
    int frameCount = 0;

    _frameTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      frameCount++;
      final frame = _generateFrame(frameCount);
      if (frame != null) {
        _poseController.add(frame);
      }
    });
  }

  PoseFrame? _generateFrame(int frameCount) {
    switch (scenario) {
      case MockScenario.normal:
        return _normalFrame(frameCount);
      case MockScenario.obliqueApproach:
        return _obliqueFrame(frameCount);
      case MockScenario.trackingGlitch:
        return _glitchFrame(frameCount);
      case MockScenario.gradualDrift:
        return _driftFrame(frameCount);
      case MockScenario.realistic:
        return _realisticFrame(frameCount);
    }
  }

  /// Normal scenario: good angle, low noise, stable tracking.
  PoseFrame _normalFrame(int frameCount) {
    final noise = 0.0005; // 0.5mm noise
    return PoseFrame(
      position: Vector3(
        _qrPosition.x + _gaussian() * noise,
        _qrPosition.y + _gaussian() * noise,
        _qrPosition.z + _gaussian() * noise,
      ),
      quaternion: _addRotationNoise(_qrRotation, 0.5), // 0.5° noise
      reprojectionError: 0.5 + _rng.nextDouble() * 1.5,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      angleScore: 0.96 + _rng.nextDouble() * 0.04, // 0.96-1.0
    );
  }

  /// Oblique approach: angle too steep, should fail angle gate.
  PoseFrame _obliqueFrame(int frameCount) {
    // Gradually improve angle over time (simulates user adjusting)
    final progress = (frameCount / 60.0).clamp(0.0, 1.0);
    final baseAngle = 0.7 + progress * 0.28; // 0.7 → 0.98

    return PoseFrame(
      position: Vector3(
        _qrPosition.x + _gaussian() * 0.001,
        _qrPosition.y + _gaussian() * 0.001,
        _qrPosition.z + _gaussian() * 0.001,
      ),
      quaternion: _addRotationNoise(_qrRotation, 1.0),
      reprojectionError: 1.0 + _rng.nextDouble() * 2.0,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      angleScore: baseAngle + _gaussian() * 0.02,
    );
  }

  /// Tracking glitch: occasional large jumps in position.
  PoseFrame _glitchFrame(int frameCount) {
    final isGlitch = frameCount % 12 == 0; // Every 12th frame glitches
    final noise = isGlitch ? 0.05 : 0.0005; // 50mm vs 0.5mm

    return PoseFrame(
      position: Vector3(
        _qrPosition.x + _gaussian() * noise,
        _qrPosition.y + _gaussian() * noise,
        _qrPosition.z + _gaussian() * noise,
      ),
      quaternion: _addRotationNoise(
        _qrRotation,
        isGlitch ? 15.0 : 0.5,
      ),
      reprojectionError: isGlitch ? 5.0 + _rng.nextDouble() * 3.0 : 1.0,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      angleScore: 0.97 + _rng.nextDouble() * 0.03,
    );
  }

  /// Gradual drift: position slowly moves (tests spatial clustering).
  PoseFrame _driftFrame(int frameCount) {
    final driftRate = 0.0001; // 0.1mm per frame = 3mm/sec
    final drift = frameCount * driftRate;

    return PoseFrame(
      position: Vector3(
        _qrPosition.x + drift + _gaussian() * 0.0005,
        _qrPosition.y + _gaussian() * 0.0005,
        _qrPosition.z + _gaussian() * 0.0005,
      ),
      quaternion: _addRotationNoise(_qrRotation, 0.3),
      reprojectionError: 0.8 + _rng.nextDouble() * 1.0,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      angleScore: 0.97 + _rng.nextDouble() * 0.03,
    );
  }

  /// Realistic scenario: mix of good frames, occasional bad angle,
  /// rare glitches, slight noise variation.
  PoseFrame _realisticFrame(int frameCount) {
    // Simulate user hand tremor (varies over time)
    final tremor = 0.0003 + 0.0004 * sin(frameCount * 0.1).abs();

    // Occasional angle dip (user shifts weight)
    final angleDip = (frameCount % 40 < 3) ? -0.06 : 0.0;

    // Rare tracking glitch (1 in 50 frames)
    final isGlitch = _rng.nextInt(50) == 0;
    final glitchNoise = isGlitch ? 0.02 : 0.0;

    return PoseFrame(
      position: Vector3(
        _qrPosition.x + _gaussian() * (tremor + glitchNoise),
        _qrPosition.y + _gaussian() * (tremor + glitchNoise),
        _qrPosition.z + _gaussian() * (tremor + glitchNoise),
      ),
      quaternion: _addRotationNoise(
        _qrRotation,
        isGlitch ? 8.0 : 0.3 + tremor * 500,
      ),
      reprojectionError: isGlitch
          ? 4.0 + _rng.nextDouble() * 2.0
          : 0.5 + _rng.nextDouble() * 1.5,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      angleScore: (0.97 + _rng.nextDouble() * 0.03 + angleDip)
          .clamp(0.0, 1.0),
    );
  }

  // --- Utilities ---

  Quaternion _addRotationNoise(Quaternion base, double maxDegrees) {
    final angle = radians(_gaussian() * maxDegrees);
    final axis = Vector3(
      _rng.nextDouble() - 0.5,
      _rng.nextDouble() - 0.5,
      _rng.nextDouble() - 0.5,
    )..normalize();
    final noise = Quaternion.axisAngle(axis, angle);
    return (noise * base).normalized();
  }

  double _gaussian() {
    final u1 = _rng.nextDouble();
    final u2 = _rng.nextDouble();
    return sqrt(-2.0 * log(u1)) * cos(2.0 * pi * u2);
  }

  @override
  void dispose() {
    _frameTimer?.cancel();
    _poseController.close();
  }
}

/// Available simulation scenarios for testing.
enum MockScenario {
  /// Good conditions: low noise, good angle, stable tracking.
  normal,

  /// Camera approaching from oblique angle, gradually correcting.
  obliqueApproach,

  /// Occasional large tracking jumps (ARCore glitches).
  trackingGlitch,

  /// Position slowly drifts over time.
  gradualDrift,

  /// Mix of all conditions — most realistic.
  realistic,
}
