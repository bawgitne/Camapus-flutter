import 'package:vector_math/vector_math_64.dart';

/// Raw pose data from a single AR frame where QR was detected.
class PoseFrame {
  /// Position in AR world coordinates (meters).
  final Vector3 position;

  /// Orientation as quaternion (x, y, z, w).
  final Quaternion quaternion;

  /// Reprojection error reported by the AR system (pixels).
  final double reprojectionError;

  /// Timestamp in milliseconds since epoch.
  final int timestampMs;

  /// Dot product between camera forward and QR normal.
  /// Used for angle gate check.
  final double angleScore;

  const PoseFrame({
    required this.position,
    required this.quaternion,
    required this.reprojectionError,
    required this.timestampMs,
    required this.angleScore,
  });

  /// Whether this frame passes the canonical approach angle check.
  /// dot product > cos(20°) ≈ 0.9397
  bool get passesAngleGate => angleScore > 0.9397;

  /// Create from raw platform channel data.
  factory PoseFrame.fromMap(Map<String, dynamic> map) {
    final pos = map['position'] as List<dynamic>;
    final quat = map['quaternion'] as List<dynamic>;

    return PoseFrame(
      position: Vector3(
        (pos[0] as num).toDouble(),
        (pos[1] as num).toDouble(),
        (pos[2] as num).toDouble(),
      ),
      quaternion: Quaternion(
        (quat[0] as num).toDouble(),
        (quat[1] as num).toDouble(),
        (quat[2] as num).toDouble(),
        (quat[3] as num).toDouble(),
      ),
      reprojectionError: (map['reprojectionError'] as num).toDouble(),
      timestampMs: map['timestampMs'] as int,
      angleScore: (map['angleScore'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toMap() => {
        'position': [position.x, position.y, position.z],
        'quaternion': [quaternion.x, quaternion.y, quaternion.z, quaternion.w],
        'reprojectionError': reprojectionError,
        'timestampMs': timestampMs,
        'angleScore': angleScore,
      };
}
