import 'dart:math';
import 'package:vector_math/vector_math_64.dart';

/// Result of gravity alignment with validation metrics.
class GravityAlignmentResult {
  /// The gravity-aligned pose matrix.
  final Matrix4 alignedMatrix;

  /// Angular delta before alignment (degrees).
  final double preDeltaDeg;

  /// Angular delta after alignment (degrees). Should be ~0.
  final double postDeltaDeg;

  /// How much the heading (yaw) was preserved (degrees of change).
  /// Should be ~0 if alignment only corrected roll/pitch.
  final double headingChangeDeg;

  /// Whether the gravity vector was considered reliable.
  final bool gravityReliable;

  /// The gravity vector magnitude (should be ~9.81 m/s²).
  final double gravityMagnitude;

  const GravityAlignmentResult({
    required this.alignedMatrix,
    required this.preDeltaDeg,
    required this.postDeltaDeg,
    required this.headingChangeDeg,
    required this.gravityReliable,
    required this.gravityMagnitude,
  });

  /// Whether the alignment is considered valid.
  /// Post-delta should be < 0.1° and heading change < 2°.
  bool get isValid => postDeltaDeg < 0.1 && headingChangeDeg < 2.0;
}

/// Aligns a pose matrix's Y-axis to the gravity vector from IMU.
///
/// This is critical for cross-device consistency:
/// - IMU gravity accuracy: ~0.1° (much better than visual pose estimation)
/// - Removes roll/pitch error from camera orientation during scan
/// - Ensures "up" is always physically "up" regardless of phone tilt
/// - Preserves heading (yaw around vertical) from QR detection
///
/// The gravity vector from ARCore/ARKit is fused from accelerometer +
/// gyroscope, providing stable direction even during motion.
class GravityAligner {
  /// Expected gravity magnitude (m/s²).
  static const double _expectedGravity = 9.81;

  /// Tolerance for gravity magnitude validation (±).
  static const double _gravityTolerance = 0.5;

  /// Perform full gravity alignment with validation.
  ///
  /// [poseMatrix] - the averaged pose from QR detection
  /// [gravityVector] - raw gravity from IMU (points downward, ~9.81 m/s²)
  /// [gravityHistory] - optional: multiple gravity samples for averaging
  ///
  /// Returns detailed result with metrics for debugging.
  static GravityAlignmentResult alignWithValidation(
    Matrix4 poseMatrix,
    Vector3 gravityVector, {
    List<Vector3>? gravityHistory,
  }) {
    // Step 1: Validate and optionally average gravity vector
    final gravity = gravityHistory != null && gravityHistory.length >= 3
        ? _averageGravity(gravityHistory)
        : gravityVector;

    final gravityMag = gravity.length;
    final gravityReliable = (gravityMag - _expectedGravity).abs() < _gravityTolerance;

    // Step 2: Compute pre-alignment delta
    final preDelta = computeGravityDelta(poseMatrix, gravity);

    // Step 3: Extract heading (yaw) before alignment
    final preHeading = _extractHeading(poseMatrix, gravity);

    // Step 4: Perform alignment
    final aligned = alignToGravity(poseMatrix, gravity);

    // Step 5: Compute post-alignment delta (should be ~0)
    final postDelta = computeGravityDelta(aligned, gravity);

    // Step 6: Check heading preservation
    final postHeading = _extractHeading(aligned, gravity);
    final headingChange = _angleDifference(preHeading, postHeading).abs();

    return GravityAlignmentResult(
      alignedMatrix: aligned,
      preDeltaDeg: preDelta,
      postDeltaDeg: postDelta,
      headingChangeDeg: headingChange,
      gravityReliable: gravityReliable,
      gravityMagnitude: gravityMag,
    );
  }

  /// Align the Y-axis of [poseMatrix] to the [gravityVector].
  ///
  /// The gravity vector should point downward (as reported by IMU).
  /// We snap Y-axis to -gravity (i.e., "up"), preserving the heading
  /// (yaw around vertical axis) from the original QR detection.
  ///
  /// Uses Gram-Schmidt orthogonalization to rebuild an orthonormal basis.
  static Matrix4 alignToGravity(Matrix4 poseMatrix, Vector3 gravityVector) {
    // Extract current axes from pose matrix
    final currentX = Vector3(
      poseMatrix.entry(0, 0),
      poseMatrix.entry(1, 0),
      poseMatrix.entry(2, 0),
    );
    final currentZ = Vector3(
      poseMatrix.entry(0, 2),
      poseMatrix.entry(1, 2),
      poseMatrix.entry(2, 2),
    );

    // "Up" is opposite to gravity direction
    final up = (-gravityVector).normalized();

    // Rebuild orthonormal basis using Gram-Schmidt:
    // 1. Y-axis = gravity-aligned up
    final newY = up;

    // 2. Z-axis = project current Z onto plane perpendicular to newY
    //    This preserves the heading/yaw from QR detection
    var newZ = currentZ - newY * currentZ.dot(newY);
    if (newZ.length < 0.001) {
      // Fallback: if Z is parallel to Y, use X to derive Z
      newZ = currentX.cross(newY);
    }
    newZ.normalize();

    // 3. X-axis = Y cross Z (right-hand rule)
    final newX = newY.cross(newZ)..normalize();

    // Extract position from original matrix
    final position = Vector3(
      poseMatrix.entry(0, 3),
      poseMatrix.entry(1, 3),
      poseMatrix.entry(2, 3),
    );

    // Build new matrix with aligned axes (column-major)
    return Matrix4(
      newX.x, newX.y, newX.z, 0.0, // column 0 (X-axis)
      newY.x, newY.y, newY.z, 0.0, // column 1 (Y-axis)
      newZ.x, newZ.y, newZ.z, 0.0, // column 2 (Z-axis)
      position.x, position.y, position.z, 1.0, // column 3 (translation)
    );
  }

  /// Compute the angular difference between the pose's Y-axis and gravity.
  /// Returns angle in degrees. Should be < 0.1° after alignment.
  static double computeGravityDelta(Matrix4 poseMatrix, Vector3 gravityVector) {
    final poseY = Vector3(
      poseMatrix.entry(0, 1),
      poseMatrix.entry(1, 1),
      poseMatrix.entry(2, 1),
    );
    final up = (-gravityVector).normalized();
    final dot = poseY.dot(up).clamp(-1.0, 1.0);
    return degrees(acos(dot.toDouble()));
  }

  /// Verify that a matrix is properly gravity-aligned.
  /// Returns true if Y-axis is within [toleranceDeg] of gravity up.
  static bool isGravityAligned(
    Matrix4 poseMatrix,
    Vector3 gravityVector, {
    double toleranceDeg = 0.5,
  }) {
    return computeGravityDelta(poseMatrix, gravityVector) < toleranceDeg;
  }

  /// Verify orthonormality of the matrix axes.
  /// Returns max deviation from expected dot products (should be ~0).
  static double verifyOrthonormality(Matrix4 matrix) {
    final x = Vector3(matrix.entry(0, 0), matrix.entry(1, 0), matrix.entry(2, 0));
    final y = Vector3(matrix.entry(0, 1), matrix.entry(1, 1), matrix.entry(2, 1));
    final z = Vector3(matrix.entry(0, 2), matrix.entry(1, 2), matrix.entry(2, 2));

    // Axes should be unit length
    final lenErr = max(
      max((x.length - 1.0).abs(), (y.length - 1.0).abs()),
      (z.length - 1.0).abs(),
    );

    // Axes should be perpendicular (dot products = 0)
    final dotErr = max(
      max(x.dot(y).abs(), x.dot(z).abs()),
      y.dot(z).abs(),
    );

    return max(lenErr, dotErr);
  }

  // --- Private Helpers ---

  /// Average multiple gravity samples for better stability.
  static Vector3 _averageGravity(List<Vector3> samples) {
    final sum = Vector3.zero();
    for (final s in samples) {
      sum.add(s);
    }
    return sum / samples.length.toDouble();
  }

  /// Extract heading (yaw angle around vertical axis) from a pose matrix.
  /// Returns angle in degrees [0, 360).
  static double _extractHeading(Matrix4 poseMatrix, Vector3 gravityVector) {
    final up = (-gravityVector).normalized();

    // Project Z-axis onto horizontal plane (perpendicular to up)
    final z = Vector3(
      poseMatrix.entry(0, 2),
      poseMatrix.entry(1, 2),
      poseMatrix.entry(2, 2),
    );
    final zHorizontal = z - up * z.dot(up);

    if (zHorizontal.length < 0.001) return 0.0;
    zHorizontal.normalize();

    // Compute angle relative to a reference horizontal direction
    // Use world X as reference (arbitrary but consistent)
    final refX = Vector3(1, 0, 0);
    final refXHorizontal = refX - up * refX.dot(up);
    if (refXHorizontal.length < 0.001) return 0.0;
    refXHorizontal.normalize();

    final cosAngle = zHorizontal.dot(refXHorizontal).clamp(-1.0, 1.0);
    final sinAngle = up.dot(refXHorizontal.cross(zHorizontal));

    return degrees(atan2(sinAngle, cosAngle.toDouble()));
  }

  /// Compute shortest angular difference between two angles (degrees).
  static double _angleDifference(double a, double b) {
    var diff = b - a;
    while (diff > 180) {
      diff -= 360;
    }
    while (diff < -180) {
      diff += 360;
    }
    return diff;
  }
}
