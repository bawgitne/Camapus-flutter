import 'dart:math';
import 'package:vector_math/vector_math_64.dart';
import 'package:qr_origin/models/world_origin.dart';

/// Handles post-scan verification of the established origin.
///
/// Verification strategy:
/// 1. Place a virtual test point at a known distance from QR
/// 2. Project it onto the screen using camera intrinsics
/// 3. User confirms visual alignment with physical marker
/// 4. Optionally: compare with previously saved origin for same QR
///
/// This is the final quality gate before the origin is locked.
class OriginVerifier {
  /// Camera intrinsic parameters (from ARCore/ARKit).
  final double focalLengthX; // fx in pixels
  final double focalLengthY; // fy in pixels
  final double principalPointX; // cx in pixels
  final double principalPointY; // cy in pixels
  final int imageWidth;
  final int imageHeight;

  OriginVerifier({
    required this.focalLengthX,
    required this.focalLengthY,
    required this.principalPointX,
    required this.principalPointY,
    required this.imageWidth,
    required this.imageHeight,
  });

  /// Default constructor with typical phone camera intrinsics.
  /// These should be replaced with actual values from AR session.
  factory OriginVerifier.defaultIntrinsics() {
    return OriginVerifier(
      focalLengthX: 1000.0,
      focalLengthY: 1000.0,
      principalPointX: 540.0,
      principalPointY: 960.0,
      imageWidth: 1080,
      imageHeight: 1920,
    );
  }

  /// Generate verification test points.
  ///
  /// Returns a list of test points at known positions relative to the QR.
  /// Each point has a world position and expected screen position.
  List<VerificationPoint> generateTestPoints(WorldOrigin origin) {
    return [
      // Primary: 1m forward from QR center
      VerificationPoint(
        label: '1m Forward',
        relativePosition: Vector3(0, 0, 1.0),
        worldPosition: origin.getTestPoint(distanceM: 1.0),
      ),
      // Secondary: 0.5m forward
      VerificationPoint(
        label: '0.5m Forward',
        relativePosition: Vector3(0, 0, 0.5),
        worldPosition: origin.getTestPoint(distanceM: 0.5),
      ),
      // Lateral: 0.5m to the right at 1m forward
      VerificationPoint(
        label: '0.5m Right',
        relativePosition: Vector3(0.5, 0, 1.0),
        worldPosition: _computeWorldPoint(origin, Vector3(0.5, 0, 1.0)),
      ),
    ];
  }

  /// Project a 3D world point onto 2D screen coordinates.
  ///
  /// [worldPoint] - point in AR world space
  /// [cameraPose] - current camera pose (4×4 matrix, world-to-camera)
  ///
  /// Returns screen coordinates (x, y) in pixels, or null if behind camera.
  ScreenPoint? projectToScreen(Vector3 worldPoint, Matrix4 cameraPose) {
    // Transform world point to camera space
    final cameraInverse = Matrix4.copy(cameraPose)..invert();
    final cameraSpace = cameraInverse.transform3(worldPoint);

    // Check if point is in front of camera (positive Z in OpenGL convention,
    // but ARCore uses -Z as forward, so check accordingly)
    // In ARCore camera space: -Z is forward
    if (cameraSpace.z > 0) return null; // Behind camera

    final depth = -cameraSpace.z; // Distance from camera
    if (depth < 0.01) return null; // Too close

    // Project using pinhole camera model
    final screenX = focalLengthX * (cameraSpace.x / depth) + principalPointX;
    final screenY = focalLengthY * (cameraSpace.y / depth) + principalPointY;

    // Check if within screen bounds (with margin)
    final margin = 50.0;
    final isOnScreen = screenX >= -margin &&
        screenX <= imageWidth + margin &&
        screenY >= -margin &&
        screenY <= imageHeight + margin;

    return ScreenPoint(
      x: screenX,
      y: screenY,
      depth: depth,
      isOnScreen: isOnScreen,
    );
  }

  /// Compute the expected screen error for a given positional error.
  ///
  /// At 1m distance, 5mm positional error ≈ how many pixels on screen?
  /// This helps set user expectations during verification.
  double computePixelErrorForDistance({
    required double distanceM,
    required double positionalErrorM,
  }) {
    // pixel_error ≈ focal_length * positional_error / distance
    return focalLengthX * positionalErrorM / distanceM;
  }

  /// Run automated verification checks (no user input needed).
  VerificationReport runAutomatedChecks(WorldOrigin origin) {
    final checks = <VerificationCheck>[];

    // Check 1: Matrix orthonormality
    final orthoError = _checkOrthonormality(origin.poseMatrix);
    checks.add(VerificationCheck(
      name: 'Matrix Orthonormality',
      passed: orthoError < 0.001,
      value: orthoError,
      threshold: 0.001,
      unit: 'deviation',
    ));

    // Check 2: Position is reasonable (not at origin, not too far)
    final posLength = origin.position.length;
    checks.add(VerificationCheck(
      name: 'Position Magnitude',
      passed: posLength > 0.1 && posLength < 10.0,
      value: posLength,
      threshold: 10.0,
      unit: 'm',
    ));

    // Check 3: Up vector is roughly vertical
    final upDot = origin.up.dot(Vector3(0, 1, 0)).abs();
    checks.add(VerificationCheck(
      name: 'Up Vector Alignment',
      passed: upDot > 0.99,
      value: upDot,
      threshold: 0.99,
      unit: 'dot',
    ));

    // Check 4: Confidence above minimum
    checks.add(VerificationCheck(
      name: 'Confidence Score',
      passed: origin.confidence >= 0.5,
      value: origin.confidence,
      threshold: 0.5,
      unit: '',
    ));

    // Check 5: Position std dev within target
    checks.add(VerificationCheck(
      name: 'Position Stability',
      passed: origin.positionStdDev < 0.005, // < 5mm
      value: origin.positionStdDev * 1000,
      threshold: 5.0,
      unit: 'mm',
    ));

    // Check 6: Gravity alignment
    checks.add(VerificationCheck(
      name: 'Gravity Alignment',
      passed: origin.gravityDeltaDeg < 0.5,
      value: origin.gravityDeltaDeg,
      threshold: 0.5,
      unit: '°',
    ));

    return VerificationReport(
      checks: checks,
      allPassed: checks.every((c) => c.passed),
      timestamp: DateTime.now(),
    );
  }

  // --- Private ---

  Vector3 _computeWorldPoint(WorldOrigin origin, Vector3 relativePos) {
    final worldMatrix = origin.toAbsolute(
      Matrix4.translationValues(relativePos.x, relativePos.y, relativePos.z),
    );
    return Vector3(
      worldMatrix.entry(0, 3),
      worldMatrix.entry(1, 3),
      worldMatrix.entry(2, 3),
    );
  }

  double _checkOrthonormality(Matrix4 matrix) {
    final x = Vector3(matrix.entry(0, 0), matrix.entry(1, 0), matrix.entry(2, 0));
    final y = Vector3(matrix.entry(0, 1), matrix.entry(1, 1), matrix.entry(2, 1));
    final z = Vector3(matrix.entry(0, 2), matrix.entry(1, 2), matrix.entry(2, 2));

    final lenErr = max(
      max((x.length - 1.0).abs(), (y.length - 1.0).abs()),
      (z.length - 1.0).abs(),
    );
    final dotErr = max(
      max(x.dot(y).abs(), x.dot(z).abs()),
      y.dot(z).abs(),
    );
    return max(lenErr, dotErr);
  }
}

/// A point used for visual verification.
class VerificationPoint {
  final String label;
  final Vector3 relativePosition; // relative to origin
  final Vector3 worldPosition; // in AR world space

  const VerificationPoint({
    required this.label,
    required this.relativePosition,
    required this.worldPosition,
  });
}

/// 2D screen coordinates of a projected point.
class ScreenPoint {
  final double x;
  final double y;
  final double depth; // distance from camera in meters
  final bool isOnScreen;

  const ScreenPoint({
    required this.x,
    required this.y,
    required this.depth,
    required this.isOnScreen,
  });
}

/// Single automated verification check result.
class VerificationCheck {
  final String name;
  final bool passed;
  final double value;
  final double threshold;
  final String unit;

  const VerificationCheck({
    required this.name,
    required this.passed,
    required this.value,
    required this.threshold,
    required this.unit,
  });

  @override
  String toString() => '$name: ${passed ? "✓" : "✗"} '
      '(${value.toStringAsFixed(4)} $unit, threshold: $threshold)';
}

/// Full verification report.
class VerificationReport {
  final List<VerificationCheck> checks;
  final bool allPassed;
  final DateTime timestamp;

  const VerificationReport({
    required this.checks,
    required this.allPassed,
    required this.timestamp,
  });

  int get passedCount => checks.where((c) => c.passed).length;
  int get totalCount => checks.length;

  @override
  String toString() => 'VerificationReport: $passedCount/$totalCount passed '
      '(${allPassed ? "ALL OK" : "FAILED"})';
}
