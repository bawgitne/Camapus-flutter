import 'dart:convert';
import 'dart:math';
import 'package:vector_math/vector_math_64.dart';

/// The established world origin derived from QR scan.
///
/// RULE: All scene objects store poses RELATIVE to this origin.
/// Never store or expose absolute AR world poses.
///
/// The origin is stored as a 4×4 homogeneous transformation matrix
/// (not euler angles) to avoid gimbal lock and ensure mathematical
/// consistency across operations.
class WorldOrigin {
  /// 4x4 homogeneous transformation matrix (column-major).
  /// Transforms from origin-local space to AR world space.
  final Matrix4 poseMatrix;

  /// Identifier of the QR code used to establish this origin.
  final String qrId;

  /// When this origin was established.
  final DateTime timestamp;

  /// Number of frames used to compute this origin.
  final int frameCount;

  /// Average reprojection error of accepted frames (pixels).
  final double avgReprojectionError;

  /// Confidence score from averaging pipeline (0.0 to 1.0).
  final double confidence;

  /// Gravity alignment delta after snap (degrees). Should be < 0.1°.
  final double gravityDeltaDeg;

  /// Position standard deviation from averaging (meters).
  final double positionStdDev;

  const WorldOrigin({
    required this.poseMatrix,
    required this.qrId,
    required this.timestamp,
    required this.frameCount,
    required this.avgReprojectionError,
    this.confidence = 0.0,
    this.gravityDeltaDeg = 0.0,
    this.positionStdDev = 0.0,
  });

  // --- Pose Operations ---

  /// Get the inverse matrix (AR world → origin local).
  Matrix4 get inverseMatrix => Matrix4.copy(poseMatrix)..invert();

  /// Convert an absolute AR world pose to origin-relative pose.
  /// USE THIS for storing any object's pose.
  Matrix4 toRelative(Matrix4 absolutePose) {
    return inverseMatrix * absolutePose;
  }

  /// Convert an origin-relative pose back to AR world pose.
  /// USE THIS for rendering objects in AR.
  Matrix4 toAbsolute(Matrix4 relativePose) {
    return poseMatrix * relativePose;
  }

  /// Get a specific test point in world space.
  /// Used for verification: project this point and check alignment.
  Vector3 getTestPoint({double distanceM = 1.0}) {
    // Test point is [distanceM] meters along the origin's Z-axis (forward)
    final forward = Vector3(
      poseMatrix.entry(0, 2),
      poseMatrix.entry(1, 2),
      poseMatrix.entry(2, 2),
    );
    final origin = Vector3(
      poseMatrix.entry(0, 3),
      poseMatrix.entry(1, 3),
      poseMatrix.entry(2, 3),
    );
    return origin + forward * distanceM;
  }

  /// Get the origin position in world space.
  Vector3 get position => Vector3(
        poseMatrix.entry(0, 3),
        poseMatrix.entry(1, 3),
        poseMatrix.entry(2, 3),
      );

  /// Get the origin's forward direction (Z-axis).
  Vector3 get forward => Vector3(
        poseMatrix.entry(0, 2),
        poseMatrix.entry(1, 2),
        poseMatrix.entry(2, 2),
      );

  /// Get the origin's up direction (Y-axis, gravity-aligned).
  Vector3 get up => Vector3(
        poseMatrix.entry(0, 1),
        poseMatrix.entry(1, 1),
        poseMatrix.entry(2, 1),
      );

  /// Get the origin's right direction (X-axis).
  Vector3 get right => Vector3(
        poseMatrix.entry(0, 0),
        poseMatrix.entry(1, 0),
        poseMatrix.entry(2, 0),
      );

  // --- Serialization ---

  /// Serialize to JSON-compatible map.
  /// Matrix stored as 16 column-major doubles.
  Map<String, dynamic> toJson() => {
        'matrix': poseMatrix.storage.toList(),
        'qrId': qrId,
        'timestamp': timestamp.toIso8601String(),
        'frameCount': frameCount,
        'avgReprojectionError': avgReprojectionError,
        'confidence': confidence,
        'gravityDeltaDeg': gravityDeltaDeg,
        'positionStdDev': positionStdDev,
        'version': 1, // Schema version for future migrations
      };

  /// Serialize to JSON string.
  String toJsonString() => jsonEncode(toJson());

  /// Deserialize from JSON map.
  factory WorldOrigin.fromJson(Map<String, dynamic> json) {
    final matrixValues = (json['matrix'] as List<dynamic>)
        .map((e) => (e as num).toDouble())
        .toList();

    final matrix = Matrix4.zero();
    for (var i = 0; i < 16; i++) {
      matrix.storage[i] = matrixValues[i];
    }

    return WorldOrigin(
      poseMatrix: matrix,
      qrId: json['qrId'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      frameCount: json['frameCount'] as int,
      avgReprojectionError: (json['avgReprojectionError'] as num).toDouble(),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      gravityDeltaDeg: (json['gravityDeltaDeg'] as num?)?.toDouble() ?? 0.0,
      positionStdDev: (json['positionStdDev'] as num?)?.toDouble() ?? 0.0,
    );
  }

  /// Deserialize from JSON string.
  factory WorldOrigin.fromJsonString(String jsonStr) {
    return WorldOrigin.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
  }

  // --- Comparison ---

  /// Compute positional difference between this origin and another (meters).
  /// Used to compare origins from different scan sessions.
  double positionDifference(WorldOrigin other) {
    return (position - other.position).length;
  }

  /// Compute angular difference between this origin and another (degrees).
  /// Compares the full rotation, not just heading.
  double rotationDifference(WorldOrigin other) {
    // Extract quaternions from both matrices
    final q1 = Quaternion.fromRotation(poseMatrix.getRotation());
    final q2 = Quaternion.fromRotation(other.poseMatrix.getRotation());

    final dot = (q1.x * q2.x + q1.y * q2.y + q1.z * q2.z + q1.w * q2.w)
        .abs()
        .clamp(0.0, 1.0);
    return degrees(2.0 * acos(dot));
  }

  @override
  String toString() => 'WorldOrigin('
      'qr=$qrId, '
      'confidence=${(confidence * 100).toStringAsFixed(0)}%, '
      'σ=${(positionStdDev * 1000).toStringAsFixed(2)}mm, '
      'frames=$frameCount)';
}
