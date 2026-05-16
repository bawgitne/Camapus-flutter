import 'dart:math';
import 'package:vector_math/vector_math_64.dart';
import 'package:qr_origin/models/pose_frame.dart';

/// Collects and validates frames for multi-frame pose averaging.
///
/// Implements:
/// - Temporal coherence check (reject sudden jumps)
/// - Spatial clustering (detect if QR moved during collection)
/// - Running statistics for real-time quality assessment
class FrameCollector {
  /// Maximum allowed position jump between consecutive frames (meters).
  /// A jump larger than this indicates tracking glitch.
  final double maxPositionJump;

  /// Maximum allowed rotation jump between consecutive frames (degrees).
  final double maxRotationJump;

  /// Target number of frames to collect.
  final int targetFrameCount;

  /// Minimum frames needed for a valid result.
  final int minFrameCount;

  /// Maximum time window for collection (milliseconds).
  /// If exceeded, forces computation with whatever we have.
  final int maxCollectionTimeMs;

  // Internal state
  final List<PoseFrame> _acceptedFrames = [];
  final List<PoseFrame> _rejectedFrames = [];
  PoseFrame? _lastAcceptedFrame;
  int? _collectionStartMs;

  // Running statistics
  double _runningMeanX = 0.0;
  double _runningMeanY = 0.0;
  double _runningMeanZ = 0.0;
  double _runningM2X = 0.0; // For Welford's online variance
  double _runningM2Y = 0.0;
  double _runningM2Z = 0.0;

  FrameCollector({
    this.maxPositionJump = 0.01, // 10mm
    this.maxRotationJump = 5.0, // 5 degrees
    this.targetFrameCount = 30,
    this.minFrameCount = 15,
    this.maxCollectionTimeMs = 3000, // 3 seconds max
  });

  // --- Public API ---

  /// Current accepted frame count.
  int get acceptedCount => _acceptedFrames.length;

  /// Current rejected frame count.
  int get rejectedCount => _rejectedFrames.length;

  /// Progress towards target (0.0 to 1.0).
  double get progress => _acceptedFrames.length / targetFrameCount;

  /// Whether we have enough frames for computation.
  bool get hasEnoughFrames => _acceptedFrames.length >= minFrameCount;

  /// Whether we've reached the target frame count.
  bool get isComplete => _acceptedFrames.length >= targetFrameCount;

  /// Whether collection has timed out.
  bool get isTimedOut {
    if (_collectionStartMs == null) return false;
    final elapsed = DateTime.now().millisecondsSinceEpoch - _collectionStartMs!;
    return elapsed > maxCollectionTimeMs;
  }

  /// Get all accepted frames (immutable copy).
  List<PoseFrame> get acceptedFrames => List.unmodifiable(_acceptedFrames);

  /// Current position standard deviation (meters). Lower = more stable.
  double get positionStdDev {
    if (_acceptedFrames.length < 2) return double.infinity;
    final n = _acceptedFrames.length.toDouble();
    final varX = _runningM2X / (n - 1);
    final varY = _runningM2Y / (n - 1);
    final varZ = _runningM2Z / (n - 1);
    return sqrt(varX + varY + varZ);
  }

  /// Spatial spread of accepted frames (max distance from centroid).
  double get spatialSpread {
    if (_acceptedFrames.length < 2) return 0.0;
    final centroid = Vector3(_runningMeanX, _runningMeanY, _runningMeanZ);
    double maxDist = 0.0;
    for (final frame in _acceptedFrames) {
      final dist = (frame.position - centroid).length;
      if (dist > maxDist) maxDist = dist;
    }
    return maxDist;
  }

  /// Try to add a frame to the collection.
  /// Returns a result indicating whether it was accepted and why.
  FrameCollectionResult addFrame(PoseFrame frame) {
    // Start timer on first frame
    _collectionStartMs ??= frame.timestampMs;

    // Check temporal coherence against last accepted frame
    if (_lastAcceptedFrame != null) {
      final coherenceResult = _checkTemporalCoherence(frame);
      if (!coherenceResult.passes) {
        _rejectedFrames.add(frame);
        return coherenceResult;
      }
    }

    // Check spatial clustering (is this frame consistent with the cluster?)
    if (_acceptedFrames.length >= 3) {
      final clusterResult = _checkSpatialCluster(frame);
      if (!clusterResult.passes) {
        _rejectedFrames.add(frame);
        return clusterResult;
      }
    }

    // Frame accepted — update running statistics
    _acceptFrame(frame);

    return FrameCollectionResult(
      passes: true,
      reason: 'Frame accepted',
      positionJump: _lastAcceptedFrame != null
          ? (frame.position - _lastAcceptedFrame!.position).length
          : 0.0,
      rotationJump: 0.0,
    );
  }

  /// Reset the collector for a new scan.
  void reset() {
    _acceptedFrames.clear();
    _rejectedFrames.clear();
    _lastAcceptedFrame = null;
    _collectionStartMs = null;
    _runningMeanX = 0.0;
    _runningMeanY = 0.0;
    _runningMeanZ = 0.0;
    _runningM2X = 0.0;
    _runningM2Y = 0.0;
    _runningM2Z = 0.0;
  }

  // --- Private Methods ---

  void _acceptFrame(PoseFrame frame) {
    _acceptedFrames.add(frame);
    _lastAcceptedFrame = frame;

    // Update Welford's online algorithm for running mean/variance
    final n = _acceptedFrames.length.toDouble();
    final deltaX = frame.position.x - _runningMeanX;
    final deltaY = frame.position.y - _runningMeanY;
    final deltaZ = frame.position.z - _runningMeanZ;

    _runningMeanX += deltaX / n;
    _runningMeanY += deltaY / n;
    _runningMeanZ += deltaZ / n;

    final delta2X = frame.position.x - _runningMeanX;
    final delta2Y = frame.position.y - _runningMeanY;
    final delta2Z = frame.position.z - _runningMeanZ;

    _runningM2X += deltaX * delta2X;
    _runningM2Y += deltaY * delta2Y;
    _runningM2Z += deltaZ * delta2Z;
  }

  /// Check if the frame is temporally coherent with the previous frame.
  /// Detects sudden jumps in position or rotation.
  FrameCollectionResult _checkTemporalCoherence(PoseFrame frame) {
    final prev = _lastAcceptedFrame!;

    // Position jump check
    final posJump = (frame.position - prev.position).length;
    if (posJump > maxPositionJump) {
      return FrameCollectionResult(
        passes: false,
        reason: 'Position jump too large: ${(posJump * 1000).toStringAsFixed(1)}mm '
            '(max: ${(maxPositionJump * 1000).toStringAsFixed(1)}mm)',
        positionJump: posJump,
        rotationJump: 0.0,
      );
    }

    // Rotation jump check
    final rotJump = _quaternionAngleDeg(frame.quaternion, prev.quaternion);
    if (rotJump > maxRotationJump) {
      return FrameCollectionResult(
        passes: false,
        reason: 'Rotation jump too large: ${rotJump.toStringAsFixed(1)}° '
            '(max: ${maxRotationJump.toStringAsFixed(1)}°)',
        positionJump: posJump,
        rotationJump: rotJump,
      );
    }

    return FrameCollectionResult(
      passes: true,
      reason: 'Temporal coherence OK',
      positionJump: posJump,
      rotationJump: rotJump,
    );
  }

  /// Check if the frame belongs to the existing spatial cluster.
  /// Detects if the QR might have moved or tracking drifted.
  FrameCollectionResult _checkSpatialCluster(PoseFrame frame) {
    final centroid = Vector3(_runningMeanX, _runningMeanY, _runningMeanZ);
    final distFromCentroid = (frame.position - centroid).length;

    // Allow up to 3x the current spread + a base tolerance
    final maxDist = max(spatialSpread * 3.0, 0.005); // at least 5mm tolerance

    if (distFromCentroid > maxDist) {
      return FrameCollectionResult(
        passes: false,
        reason: 'Frame outside spatial cluster: '
            '${(distFromCentroid * 1000).toStringAsFixed(1)}mm from centroid '
            '(max: ${(maxDist * 1000).toStringAsFixed(1)}mm)',
        positionJump: distFromCentroid,
        rotationJump: 0.0,
      );
    }

    return FrameCollectionResult(
      passes: true,
      reason: 'Spatial cluster OK',
      positionJump: distFromCentroid,
      rotationJump: 0.0,
    );
  }

  /// Compute angle between two quaternions in degrees.
  double _quaternionAngleDeg(Quaternion a, Quaternion b) {
    final dot = (a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w).abs();
    final clampedDot = dot.clamp(0.0, 1.0);
    return degrees(2.0 * acos(clampedDot));
  }
}

/// Result of attempting to add a frame to the collector.
class FrameCollectionResult {
  final bool passes;
  final String reason;
  final double positionJump; // meters
  final double rotationJump; // degrees

  const FrameCollectionResult({
    required this.passes,
    required this.reason,
    required this.positionJump,
    required this.rotationJump,
  });
}
