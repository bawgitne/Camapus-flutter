import 'package:path_provider/path_provider.dart';
import 'package:qr_origin/config/app_config.dart';
import 'package:qr_origin/pipeline/angle_gate.dart';
import 'package:qr_origin/pipeline/frame_collector.dart';
import 'package:qr_origin/services/ar_service_interface.dart';
import 'package:qr_origin/services/ar_platform_service.dart';
import 'package:qr_origin/services/mock_ar_service.dart';
import 'package:qr_origin/services/origin_storage_service.dart';
import 'package:qr_origin/controllers/scan_controller.dart';

/// Simple service locator for dependency injection.
/// In a larger app, use get_it or riverpod.
class ServiceLocator {
  static OriginStorageService? _storageService;

  /// Initialize all services. Call once at app startup.
  static Future<void> initialize() async {
    final appDir = await getApplicationDocumentsDirectory();
    _storageService = OriginStorageService(
      storagePath: '${appDir.path}/qr_origin_data',
    );
  }

  /// Get the storage service.
  static OriginStorageService get storageService {
    if (_storageService == null) {
      throw StateError('ServiceLocator not initialized. Call initialize() first.');
    }
    return _storageService!;
  }

  /// Create a configured ScanController.
  static ScanController createScanController() {
    final arService = ArPlatformService();

    final angleGate = AngleGate(
      maxAngleDeg: AppConfig.maxApproachAngleDeg,
      hysteresisDeg: AppConfig.angleHysteresisDeg,
    );

    final frameCollector = FrameCollector(
      targetFrameCount: AppConfig.targetFrameCount,
      minFrameCount: AppConfig.minFrameCount,
      maxPositionJump: AppConfig.maxPositionJumpMm / 1000.0,
      maxRotationJump: AppConfig.maxRotationJumpDeg,
      maxCollectionTimeMs: AppConfig.maxCollectionTimeMs,
    );

    return ScanController(
      arService: arService,
      storageService: _storageService,
      angleGate: angleGate,
      frameCollector: frameCollector,
    );
  }
}
