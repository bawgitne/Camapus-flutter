import 'dart:math';
import 'package:vector_math/vector_math_64.dart';
import 'package:qr_origin/models/pose_frame.dart';

/// Result of the averaging computation with quality metrics.
class AveragingResult {
  final Vector3 position;
  final Quaternion quaternion;

  /// Standard deviation of positions (meters). Lower = better.
  final double positionStdDev;

  /// Angular spread of quaternions (degrees). Lower = better.
  final double rotationSpreadDeg;

  /// Ratio of frames that passed filtering.
  final double acceptanceRatio;

  /// Number of frames used in final average.
  final int usedFrameCount;

  /// Confidence score (0.0 to 1.0) based on all quality metrics.
  final double confidence;

  const AveragingResult({
    required this.position,
    required this.quaternion,
    required this.positionStdDev,
    required this.rotationSpreadDeg,
    required this.acceptanceRatio,
    required this.usedFrameCount,
    required this.confidence,
  });
}

/// Handles multi-frame pose averaging with outlier rejection.
///
/// Implements two quaternion averaging methods:
/// 1. Iterative SLERP (fast, good for small sets)
/// 2. Eigenvalue method (more accurate for larger sets with spread)
class PoseAverager {
  /// Filter frames by reprojection error using sigma-based outlier rejection.
  /// Removes frames with error > median + [maxSigma] * stddev.
  static List<PoseFrame> filterOutliers(
    List<PoseFrame> frames, {
    double maxSigma = 1.0,
  }) {
    if (frames.isEmpty) return [];

    final errors = frames.map((f) => f.reprojectionError).toList()..sort();
    final median = errors[errors.length ~/ 2];

    // Compute standard deviation
    final mean =
        errors.fold<double>(0.0, (s, e) => s + e) / errors.length;
    final variance =
        errors.fold<double>(0.0, (s, e) => s + pow(e - mean, 2)) /
            errors.length;
    final stddev = sqrt(variance);

    final threshold = median + maxSigma * stddev;

    return frames
        .where((f) => f.reprojectionError <= threshold)
        .toList();
  }

  /// Two-pass outlier rejection:
  /// 1. First pass: remove by reprojection error (sigma-based)
  /// 2. Second pass: remove positional outliers (distance from centroid)
  static List<PoseFrame> filterOutliersTwoPass(
    List<PoseFrame> frames, {
    double errorSigma = 1.0,
    double positionSigma = 2.0,
  }) {
    // Pass 1: reprojection error
    var filtered = filterOutliers(frames, maxSigma: errorSigma);
    if (filtered.length < 3) return filtered;

    // Pass 2: positional outliers
    final centroid = averagePosition(filtered);
    final distances = filtered
        .map((f) => (f.position - centroid).length)
        .toList();
    final meanDist =
        distances.fold<double>(0.0, (s, d) => s + d) / distances.length;
    final varianceDist =
        distances.fold<double>(0.0, (s, d) => s + pow(d - meanDist, 2)) /
            distances.length;
    final stddevDist = sqrt(varianceDist);
    final distThreshold = meanDist + positionSigma * stddevDist;

    filtered = filtered.where((f) {
      return (f.position - centroid).length <= distThreshold;
    }).toList();

    return filtered;
  }

  /// Full averaging pipeline with quality metrics.
  static AveragingResult computeAverage(
    List<PoseFrame> rawFrames, {
    double errorSigma = 1.0,
    double positionSigma = 2.0,
    bool useEigenMethod = true,
  }) {
    final filtered = filterOutliersTwoPass(
      rawFrames,
      errorSigma: errorSigma,
      positionSigma: positionSigma,
    );

    final position = averagePosition(filtered);
    final quaternion = useEigenMethod && filtered.length >= 4
        ? averageQuaternionEigen(filtered)
        : averageQuaternion(filtered);

    // Compute quality metrics
    final posStdDev = _computePositionStdDev(filtered, position);
    final rotSpread = _computeRotationSpread(filtered, quaternion);
    final acceptanceRatio = filtered.length / rawFrames.length;

    // Confidence: combine metrics into 0-1 score
    // Good: posStdDev < 2mm, rotSpread < 1°, acceptance > 0.7
    final posScore = (1.0 - (posStdDev / 0.005)).clamp(0.0, 1.0);
    final rotScore = (1.0 - (rotSpread / 3.0)).clamp(0.0, 1.0);
    final accScore = acceptanceRatio.clamp(0.0, 1.0);
    final confidence = (posScore * 0.4 + rotScore * 0.3 + accScore * 0.3);

    return AveragingResult(
      position: position,
      quaternion: quaternion,
      positionStdDev: posStdDev,
      rotationSpreadDeg: rotSpread,
      acceptanceRatio: acceptanceRatio,
      usedFrameCount: filtered.length,
      confidence: confidence,
    );
  }

  /// Average positions using simple arithmetic mean.
  static Vector3 averagePosition(List<PoseFrame> frames) {
    if (frames.isEmpty) return Vector3.zero();

    final sum = Vector3.zero();
    for (final frame in frames) {
      sum.add(frame.position);
    }
    return sum / frames.length.toDouble();
  }

  /// Average quaternions using iterative SLERP.
  ///
  /// Algorithm: start with first quaternion, iteratively SLERP
  /// towards each subsequent quaternion with weight 1/n.
  /// Before averaging, flips quaternions to same hemisphere to avoid
  /// the antipodal issue.
  static Quaternion averageQuaternion(List<PoseFrame> frames) {
    if (frames.isEmpty) return Quaternion.identity();
    if (frames.length == 1) return frames.first.quaternion.normalized();

    // Ensure all quaternions are in the same hemisphere as the first
    final reference = frames.first.quaternion;
    final aligned = frames.map((f) {
      final q = f.quaternion;
      final dot = _quaternionDot(q, reference);
      return dot < 0 ? _negateQuaternion(q) : q;
    }).toList();

    // Iterative SLERP averaging
    var result = aligned.first.normalized();
    for (var i = 1; i < aligned.length; i++) {
      final t = 1.0 / (i + 1); // weight for new sample
      result = _slerp(result, aligned[i].normalized(), t);
    }

    return result.normalized();
  }

  /// Average quaternions using the eigenvalue method.
  ///
  /// Constructs a 4x4 matrix M = Σ(qi * qi^T) and finds the eigenvector
  /// corresponding to the largest eigenvalue. This is the optimal average
  /// in the least-squares sense.
  ///
  /// Uses power iteration to find the dominant eigenvector (sufficient
  /// for our use case where quaternions are clustered tightly).
  static Quaternion averageQuaternionEigen(List<PoseFrame> frames) {
    if (frames.isEmpty) return Quaternion.identity();
    if (frames.length == 1) return frames.first.quaternion.normalized();

    // Ensure same hemisphere
    final reference = frames.first.quaternion;
    final quats = frames.map((f) {
      final q = f.quaternion;
      final dot = _quaternionDot(q, reference);
      return dot < 0 ? _negateQuaternion(q) : q;
    }).toList();

    // Build 4x4 accumulation matrix M = Σ(q * q^T)
    // M[i][j] = Σ(q_k[i] * q_k[j]) for all k
    final m = List.generate(4, (_) => List.filled(4, 0.0));

    for (final q in quats) {
      final v = [q.x, q.y, q.z, q.w];
      for (var i = 0; i < 4; i++) {
        for (var j = 0; j < 4; j++) {
          m[i][j] += v[i] * v[j];
        }
      }
    }

    // Power iteration to find dominant eigenvector
    var eigen = [reference.x, reference.y, reference.z, reference.w];
    _normalizeVec4(eigen);

    for (var iter = 0; iter < 50; iter++) {
      final next = [0.0, 0.0, 0.0, 0.0];
      for (var i = 0; i < 4; i++) {
        for (var j = 0; j < 4; j++) {
          next[i] += m[i][j] * eigen[j];
        }
      }
      _normalizeVec4(next);

      // Check convergence
      final diff = (next[0] - eigen[0]).abs() +
          (next[1] - eigen[1]).abs() +
          (next[2] - eigen[2]).abs() +
          (next[3] - eigen[3]).abs();
      eigen = next;
      if (diff < 1e-10) break;
    }

    return Quaternion(eigen[0], eigen[1], eigen[2], eigen[3]).normalized();
  }

  // --- Quality Metrics ---

  /// Compute standard deviation of positions around the mean.
  static double _computePositionStdDev(
      List<PoseFrame> frames, Vector3 mean) {
    if (frames.length < 2) return 0.0;
    final sumSqDist = frames.fold<double>(
      0.0,
      (sum, f) => sum + (f.position - mean).length2,
    );
    return sqrt(sumSqDist / (frames.length - 1));
  }

  /// Compute angular spread of quaternions around the mean (degrees).
  static double _computeRotationSpread(
      List<PoseFrame> frames, Quaternion mean) {
    if (frames.length < 2) return 0.0;
    final angles = frames.map((f) {
      final dot = _quaternionDot(f.quaternion, mean).abs().clamp(0.0, 1.0);
      return degrees(2.0 * acos(dot));
    });
    final meanAngle = angles.reduce((a, b) => a + b) / angles.length;
    final variance = angles
            .map((a) => pow(a - meanAngle, 2))
            .reduce((a, b) => a + b) /
        (angles.length - 1);
    return sqrt(variance);
  }

  // --- Utility ---

  static void _normalizeVec4(List<double> v) {
    final len = sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2] + v[3] * v[3]);
    if (len > 1e-10) {
      v[0] /= len;
      v[1] /= len;
      v[2] /= len;
      v[3] /= len;
    }
  }

  /// Dot product of two quaternions.
  static double _quaternionDot(Quaternion a, Quaternion b) {
    return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
  }

  /// Negate a quaternion (represents same rotation).
  static Quaternion _negateQuaternion(Quaternion q) {
    return Quaternion(-q.x, -q.y, -q.z, -q.w);
  }

  /// Spherical linear interpolation between two quaternions.
  static Quaternion _slerp(Quaternion a, Quaternion b, double t) {
    var dot = _quaternionDot(a, b);

    // Clamp dot to valid range
    dot = dot.clamp(-1.0, 1.0);

    if (dot > 0.9995) {
      // Quaternions are very close, use linear interpolation
      return Quaternion(
        a.x + t * (b.x - a.x),
        a.y + t * (b.y - a.y),
        a.z + t * (b.z - a.z),
        a.w + t * (b.w - a.w),
      ).normalized();
    }

    final theta0 = acos(dot);
    final theta = theta0 * t;
    final sinTheta = sin(theta);
    final sinTheta0 = sin(theta0);

    final s0 = cos(theta) - dot * sinTheta / sinTheta0;
    final s1 = sinTheta / sinTheta0;

    return Quaternion(
      s0 * a.x + s1 * b.x,
      s0 * a.y + s1 * b.y,
      s0 * a.z + s1 * b.z,
      s0 * a.w + s1 * b.w,
    ).normalized();
  }
}
