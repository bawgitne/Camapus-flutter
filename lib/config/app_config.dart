/// App-wide configuration flags.
/// Toggle these for development vs production builds.
class AppConfig {
  /// Use mock AR service instead of real ARCore.
  /// Set to true for UI development on any device (even emulator).
  /// Set to false for real AR testing on physical device.
  static const bool useMockAr = false;

  /// Which mock scenario to use (only relevant when useMockAr = true).
  /// Options: normal, obliqueApproach, trackingGlitch, gradualDrift, realistic
  static const String mockScenario = 'realistic';

  /// Show debug overlay by default on app start.
  static const bool showDebugByDefault = true;

  /// Angle gate configuration
  static const double maxApproachAngleDeg = 20.0;
  static const double angleHysteresisDeg = 5.0;

  /// Frame collector configuration
  static const int targetFrameCount = 30;
  static const int minFrameCount = 15;
  static const double maxPositionJumpMm = 10.0; // mm
  static const double maxRotationJumpDeg = 5.0;
  static const int maxCollectionTimeMs = 3000;

  /// QR physical size in meters (MUST match actual printed size)
  static const double qrPhysicalSizeM = 0.15; // 15cm

  /// Minimum confidence to accept origin
  static const double minConfidence = 0.5;
}
