import 'dart:async';
import 'package:vector_math/vector_math_64.dart';
import 'package:qr_origin/models/pose_frame.dart';

/// Abstract interface for AR services.
/// Both real ARCore and mock implementations conform to this.
abstract class ArServiceInterface {
  /// Stream of pose frames from QR detection.
  Stream<PoseFrame> get poseFrameStream;

  /// Last known gravity vector from IMU (points downward).
  Vector3? get lastGravityVector;

  /// ID of the currently detected QR code.
  String? get detectedQrId;

  /// Initialize the AR session.
  Future<void> initialize();

  /// Clean up resources.
  void dispose();
}
