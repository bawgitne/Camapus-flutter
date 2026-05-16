import 'dart:async';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:qr_origin/models/pose_frame.dart';
import 'package:qr_origin/services/ar_service_interface.dart';

/// Service that bridges the native AR platform (ARCore/ARKit)
/// with the Dart pose pipeline via platform channels.
class ArPlatformService implements ArServiceInterface {
  static const MethodChannel _methodChannel =
      MethodChannel('qr_origin/ar_method');
  static const EventChannel _eventChannel =
      EventChannel('qr_origin/ar_events');

  final StreamController<PoseFrame> _poseController =
      StreamController<PoseFrame>.broadcast();

  StreamSubscription? _eventSub;

  /// Last known gravity vector from IMU (points downward).
  @override
  Vector3? lastGravityVector;

  /// ID of the currently detected QR code.
  @override
  String? detectedQrId;

  /// Stream of pose frames from QR detection.
  @override
  Stream<PoseFrame> get poseFrameStream => _poseController.stream;

  /// Initialize the AR session on the native side.
  @override
  Future<void> initialize() async {
    try {
      await _methodChannel.invokeMethod('initialize', {
        'qrPhysicalSize': 0.15, // 15cm QR code
      });

      // Listen to native event stream
      _eventSub = _eventChannel
          .receiveBroadcastStream()
          .listen(_handleNativeEvent, onError: _handleError);
    } on PlatformException catch (e) {
      print('AR initialization failed: ${e.message}');
      rethrow;
    }
  }

  /// Handle events from native AR platform.
  void _handleNativeEvent(dynamic event) {
    if (event is! Map) return;
    final map = Map<String, dynamic>.from(event);

    final type = map['type'] as String?;

    switch (type) {
      case 'poseFrame':
        final frame = PoseFrame.fromMap(map['data'] as Map<String, dynamic>);
        _poseController.add(frame);
        break;

      case 'gravity':
        final g = map['data'] as List<dynamic>;
        lastGravityVector = Vector3(
          (g[0] as num).toDouble(),
          (g[1] as num).toDouble(),
          (g[2] as num).toDouble(),
        );
        break;

      case 'qrDetected':
        detectedQrId = map['data'] as String?;
        break;

      case 'trackingLost':
        // QR no longer visible — could pause collection
        break;
    }
  }

  void _handleError(dynamic error) {
    print('AR event stream error: $error');
  }

  /// Pause the AR session (e.g., when app goes to background).
  Future<void> pause() async {
    await _methodChannel.invokeMethod('pause');
  }

  /// Resume the AR session.
  Future<void> resume() async {
    await _methodChannel.invokeMethod('resume');
  }

  /// Clean up resources.
  @override
  void dispose() {
    _eventSub?.cancel();
    _poseController.close();
    _methodChannel.invokeMethod('dispose');
  }
}
