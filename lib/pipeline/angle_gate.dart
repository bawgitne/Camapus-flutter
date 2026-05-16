import 'dart:math';
import 'package:vector_math/vector_math_64.dart';

/// Result of an angle gate evaluation.
class AngleGateResult {
  /// The dot product between camera forward and QR normal.
  /// 1.0 = perfectly perpendicular, 0.0 = parallel (worst).
  final double dotProduct;

  /// Whether the frame passes the angle threshold.
  final bool passes;

  /// The approach angle in degrees (0° = perfect, 90° = parallel).
  final double approachAngleDeg;

  /// Decomposed tilt components for UI feedback.
  final double horizontalTiltDeg; // left-right tilt
  final double verticalTiltDeg; // up-down tilt

  /// Suggested correction direction for the user.
  final AngleCorrectionHint hint;

  const AngleGateResult({
    required this.dotProduct,
    required this.passes,
    required this.approachAngleDeg,
    required this.horizontalTiltDeg,
    required this.verticalTiltDeg,
    required this.hint,
  });
}

/// Hint for user to correct their approach angle.
enum AngleCorrectionHint {
  /// Angle is good, no correction needed.
  none,

  /// Tilt phone more to the left.
  tiltLeft,

  /// Tilt phone more to the right.
  tiltRight,

  /// Tilt phone upward (point more down at QR).
  tiltUp,

  /// Tilt phone downward (point more straight at QR).
  tiltDown,

  /// Too far off — general "face QR straight on" message.
  faceDirectly,
}

/// Evaluates whether the camera approach angle to the QR code
/// is within acceptable bounds for accurate pose extraction.
///
/// The core principle: perspective distortion increases with oblique angles,
/// causing corner detection errors that propagate into pose estimation.
/// By enforcing near-perpendicular viewing, we minimize this error source.
class AngleGate {
  /// Maximum allowed approach angle in degrees.
  /// Default: 20° (dot product threshold = cos(20°) ≈ 0.9397)
  final double maxAngleDeg;

  /// Computed threshold from maxAngleDeg.
  late final double _dotThreshold;

  /// Hysteresis: once collecting, allow slightly worse angle
  /// to avoid flickering at the boundary.
  final double hysteresisDeg;

  /// History of recent angle scores for smoothing.
  final List<double> _angleHistory = [];
  static const int _historySize = 5;

  AngleGate({
    this.maxAngleDeg = 20.0,
    this.hysteresisDeg = 5.0,
  }) {
    _dotThreshold = cos(radians(maxAngleDeg));
  }

  /// Get the relaxed threshold (used when already collecting).
  double get _relaxedThreshold => cos(radians(maxAngleDeg + hysteresisDeg));

  /// Evaluate a frame's approach angle.
  ///
  /// [cameraForward] - the camera's forward direction (-Z axis of camera pose)
  /// [qrNormal] - the QR code's surface normal (Z axis of QR pose)
  /// [isCurrentlyCollecting] - whether we're already in collection mode
  ///
  /// Returns detailed result with pass/fail and correction hints.
  AngleGateResult evaluate({
    required Vector3 cameraForward,
    required Vector3 qrNormal,
    bool isCurrentlyCollecting = false,
  }) {
    // Normalize inputs
    final camFwd = cameraForward.normalized();
    final qrNorm = qrNormal.normalized();

    // The camera should be looking AT the QR, so camera forward
    // should be roughly opposite to QR normal.
    // dot(camForward, -qrNormal) should be close to 1.0
    // Equivalently: |dot(camForward, qrNormal)| should be close to 1.0
    final dot = camFwd.dot(qrNorm).abs();

    // Smooth the angle score
    _angleHistory.add(dot);
    if (_angleHistory.length > _historySize) {
      _angleHistory.removeAt(0);
    }
    final smoothedDot = _angleHistory.reduce((a, b) => a + b) / _angleHistory.length;

    // Compute approach angle
    final approachAngle = degrees(acos(smoothedDot.clamp(0.0, 1.0)));

    // Determine pass/fail with hysteresis
    final threshold = isCurrentlyCollecting ? _relaxedThreshold : _dotThreshold;
    final passes = smoothedDot >= threshold;

    // Decompose the tilt into horizontal and vertical components
    // for directional feedback
    final decomposed = _decomposeTilt(camFwd, qrNorm);

    // Generate correction hint
    final hint = _generateHint(
      passes: passes,
      horizontalTilt: decomposed.$1,
      verticalTilt: decomposed.$2,
      approachAngle: approachAngle,
    );

    return AngleGateResult(
      dotProduct: smoothedDot,
      passes: passes,
      approachAngleDeg: approachAngle,
      horizontalTiltDeg: decomposed.$1,
      verticalTiltDeg: decomposed.$2,
      hint: hint,
    );
  }

  /// Evaluate directly from a PoseFrame's pre-computed angle score.
  /// Faster path when native side already computed the dot product.
  AngleGateResult evaluateFromScore(
    double angleScore, {
    bool isCurrentlyCollecting = false,
  }) {
    _angleHistory.add(angleScore);
    if (_angleHistory.length > _historySize) {
      _angleHistory.removeAt(0);
    }
    final smoothed = _angleHistory.reduce((a, b) => a + b) / _angleHistory.length;

    final threshold = isCurrentlyCollecting ? _relaxedThreshold : _dotThreshold;
    final passes = smoothed >= threshold;
    final approachAngle = degrees(acos(smoothed.clamp(0.0, 1.0)));

    return AngleGateResult(
      dotProduct: smoothed,
      passes: passes,
      approachAngleDeg: approachAngle,
      horizontalTiltDeg: 0.0, // Not available without full vectors
      verticalTiltDeg: 0.0,
      hint: passes ? AngleCorrectionHint.none : AngleCorrectionHint.faceDirectly,
    );
  }

  /// Decompose the angular offset into horizontal and vertical components.
  /// Returns (horizontalDeg, verticalDeg) where positive = right/down.
  (double, double) _decomposeTilt(Vector3 cameraForward, Vector3 qrNormal) {
    // Project the angular difference onto horizontal and vertical planes
    // relative to the QR's local coordinate system.

    // Ideal direction: -qrNormal (camera should face opposite to QR normal)
    final ideal = -qrNormal;
    final diff = cameraForward - ideal;

    // Assume world up is Y (will be corrected by gravity later)
    final worldUp = Vector3(0, 1, 0);

    // Horizontal component: project diff onto the horizontal plane
    final right = qrNormal.cross(worldUp)..normalize();
    final horizontalDeg = degrees(asin(diff.dot(right).clamp(-1.0, 1.0)));

    // Vertical component: project diff onto the vertical plane
    final up = right.cross(qrNormal)..normalize();
    final verticalDeg = degrees(asin(diff.dot(up).clamp(-1.0, 1.0)));

    return (horizontalDeg, verticalDeg);
  }

  /// Generate a user-friendly correction hint.
  AngleCorrectionHint _generateHint({
    required bool passes,
    required double horizontalTilt,
    required double verticalTilt,
    required double approachAngle,
  }) {
    if (passes) return AngleCorrectionHint.none;

    // If very far off, just say face directly
    if (approachAngle > 45.0) return AngleCorrectionHint.faceDirectly;

    // Determine dominant tilt direction
    if (horizontalTilt.abs() > verticalTilt.abs()) {
      return horizontalTilt > 0
          ? AngleCorrectionHint.tiltLeft
          : AngleCorrectionHint.tiltRight;
    } else {
      return verticalTilt > 0
          ? AngleCorrectionHint.tiltUp
          : AngleCorrectionHint.tiltDown;
    }
  }

  /// Reset smoothing history (e.g., when restarting scan).
  void reset() {
    _angleHistory.clear();
  }
}
