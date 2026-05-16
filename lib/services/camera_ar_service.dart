import 'dart:async';
import 'dart:math';
import 'dart:ui' show Size, Offset;
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors, Plane;
import 'package:qr_origin/models/pose_frame.dart';
import 'package:qr_origin/models/qr_detection.dart';
import 'package:qr_origin/services/ar_service_interface.dart';

/// Real camera-based AR service.
class CameraArService implements ArServiceInterface {
  CameraController? _cameraController;
  CameraDescription? _camera;
  final BarcodeScanner _barcodeScanner = BarcodeScanner(
    formats: [BarcodeFormat.qrCode],
  );

  final StreamController<PoseFrame> _poseController =
      StreamController<PoseFrame>.broadcast();
  final StreamController<QrDetection> _detectionController =
      StreamController<QrDetection>.broadcast();

  StreamSubscription? _gravitySub;
  bool _isProcessing = false;
  int _frameCount = 0;

  final double qrPhysicalSize;
  double _focalLength = 800.0;
  int _sensorOrientation = 90;
  double _imageWidth = 0;
  double _imageHeight = 0;

  @override
  Vector3? lastGravityVector = Vector3(0.0, -9.81, 0.0);
  @override
  String? detectedQrId;
  @override
  Stream<PoseFrame> get poseFrameStream => _poseController.stream;

  CameraController? get cameraController => _cameraController;
  Stream<QrDetection> get detectionStream => _detectionController.stream;

  CameraArService({this.qrPhysicalSize = 0.15});

  @override
  Future<void> initialize() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) throw Exception('No cameras available');

    _camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _sensorOrientation = _camera!.sensorOrientation;

    _cameraController = CameraController(
      _camera!,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );

    await _cameraController!.initialize();

    final previewSize = _cameraController!.value.previewSize!;
    _imageWidth = previewSize.width;
    _imageHeight = previewSize.height;
    _focalLength = _imageHeight / (2.0 * tan(30.0 * pi / 180.0));

    await _cameraController!.startImageStream(_processImage);

    _gravitySub = accelerometerEventStream().listen((event) {
      lastGravityVector = Vector3(event.x, event.y, event.z);
    });
  }

  void _processImage(CameraImage image) {
    if (_isProcessing) return;
    _isProcessing = true;
    _frameCount++;

    if (_frameCount % 2 != 0) {
      _isProcessing = false;
      return;
    }

    _detectQr(image).then((_) {
      _isProcessing = false;
    }).catchError((_) {
      _isProcessing = false;
    });
  }

  Future<void> _detectQr(CameraImage image) async {
    final inputImage = _buildInputImage(image);
    if (inputImage == null) return;

    final barcodes = await _barcodeScanner.processImage(inputImage);

    for (final barcode in barcodes) {
      if (barcode.cornerPoints == null || barcode.cornerPoints!.length < 4) {
        continue;
      }

      detectedQrId = barcode.rawValue ?? 'unknown';
      final corners = barcode.cornerPoints!;

      // Convert corners from image coordinates to screen coordinates.
      // ML Kit returns corners in the rotated image space.
      // We need to map them to the screen preview space.
      final screenCorners = corners.map((c) {
        return _imageToScreen(c.x.toDouble(), c.y.toDouble(), image);
      }).toList();

      _detectionController.add(QrDetection(
        corners: screenCorners,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      ));

      // Also emit pose frame for the pipeline
      final poseData = _estimatePose(corners, image.width.toDouble(), image.height.toDouble());
      if (poseData != null) {
        _poseController.add(poseData);
      }
    }
  }

  /// Map a point from image coordinates to screen preview coordinates.
  /// Handles sensor rotation (typically 90° on Android).
  Offset _imageToScreen(double ix, double iy, CameraImage image) {
    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();

    double sx, sy;

    // Android back camera sensor is typically rotated 90° clockwise.
    // Image comes in landscape (width > height) but preview is portrait.
    switch (_sensorOrientation) {
      case 90:
        // Rotate 90° CW: (x, y) -> (y, imgW - x)
        sx = iy;
        sy = imgW - ix;
        // Now in portrait space: width=imgH, height=imgW
        // Normalize to 0..1
        sx = sx / imgH;
        sy = sy / imgW;
        break;
      case 270:
        sx = imgH - iy;
        sy = ix;
        sx = sx / imgH;
        sy = sy / imgW;
        break;
      case 180:
        sx = (imgW - ix) / imgW;
        sy = (imgH - iy) / imgH;
        break;
      default: // 0
        sx = ix / imgW;
        sy = iy / imgH;
        break;
    }

    // sx, sy are now normalized 0..1 in screen portrait space.
    // The actual screen size will be applied in the overlay widget.
    // Store as normalized coordinates (0..1).
    return Offset(sx, sy);
  }

  PoseFrame? _estimatePose(
    List<Point<int>> corners,
    double imageWidth,
    double imageHeight,
  ) {
    final cx = imageWidth / 2.0;
    final cy = imageHeight / 2.0;

    final pts = corners.map((c) => Point<double>(
      c.x.toDouble() - cx,
      c.y.toDouble() - cy,
    )).toList();

    final side1 = _dist(pts[0], pts[1]);
    final side2 = _dist(pts[1], pts[2]);
    final side3 = _dist(pts[2], pts[3]);
    final side4 = _dist(pts[3], pts[0]);
    final avgSidePx = (side1 + side2 + side3 + side4) / 4.0;

    if (avgSidePx < 20) return null;

    final distance = (_focalLength * qrPhysicalSize) / avgSidePx;

    final centerX = (pts[0].x + pts[1].x + pts[2].x + pts[3].x) / 4.0;
    final centerY = (pts[0].y + pts[1].y + pts[2].y + pts[3].y) / 4.0;

    final worldX = (centerX * distance) / _focalLength;
    final worldY = (centerY * distance) / _focalLength;

    final dx = pts[1].x - pts[0].x;
    final dy = pts[1].y - pts[0].y;
    final rollAngle = atan2(dy, dx);

    final topWidth = _dist(pts[0], pts[1]);
    final bottomWidth = _dist(pts[3], pts[2]);
    final leftHeight = _dist(pts[0], pts[3]);
    final rightHeight = _dist(pts[1], pts[2]);

    final horizRatio = (topWidth / bottomWidth).clamp(0.5, 2.0);
    final vertRatio = (leftHeight / rightHeight).clamp(0.5, 2.0);

    final pitch = atan((vertRatio - 1.0) / 2.0);
    final yaw = atan((horizRatio - 1.0) / 2.0);

    final quat = Quaternion.euler(yaw, pitch, rollAngle);

    final sideVariance = [side1, side2, side3, side4]
        .map((s) => pow(s - avgSidePx, 2))
        .reduce((a, b) => a + b) / 4.0;
    final normalizedVariance = sideVariance / (avgSidePx * avgSidePx);
    final angleScore = (1.0 - normalizedVariance * 10.0).clamp(0.0, 1.0);
    final reprojError = normalizedVariance * 100.0;

    return PoseFrame(
      position: Vector3(worldX, worldY, -distance),
      quaternion: quat,
      reprojectionError: reprojError.clamp(0.0, 10.0),
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      angleScore: angleScore,
    );
  }

  double _dist(Point<double> a, Point<double> b) {
    return sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2));
  }

  InputImage? _buildInputImage(CameraImage image) {
    try {
      final bytes = Uint8List.fromList(
        image.planes.fold<List<int>>([], (prev, plane) {
          prev.addAll(plane.bytes);
          return prev;
        }),
      );

      // Use correct rotation based on sensor orientation
      final rotation = _inputRotationFromSensor(_sensorOrientation);

      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } catch (e) {
      return null;
    }
  }

  InputImageRotation _inputRotationFromSensor(int sensorOrientation) {
    switch (sensorOrientation) {
      case 0:
        return InputImageRotation.rotation0deg;
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      default:
        return InputImageRotation.rotation90deg;
    }
  }

  @override
  void dispose() {
    _gravitySub?.cancel();
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _barcodeScanner.close();
    _poseController.close();
    _detectionController.close();
  }
}
