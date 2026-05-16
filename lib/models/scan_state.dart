/// State machine for the QR scanning flow.
enum ScanState {
  /// Waiting for QR to appear in camera view.
  scanning,

  /// QR detected, collecting frames for averaging.
  collecting,

  /// Enough frames collected, computing averaged pose.
  averaging,

  /// Origin computed, waiting for user verification.
  verifying,

  /// Origin verified and locked. Ready for navigation.
  locked,
}
