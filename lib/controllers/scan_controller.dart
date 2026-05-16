import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:qr_origin/models/pose_frame.dart';
import 'package:qr_origin/models/scan_state.dart';
import 'package:qr_origin/models/world_origin.dart';
import 'package:qr_origin/services/ar_service_interface.dart';
import 'package:qr_origin/services/origin_storage_service.dart';
import 'package:qr_origin/pipeline/angle_gate.dart';
import 'package:qr_origin/pipeline/frame_collector.dart';
import 'package:qr_origin/pipeline/pose_averager.dart';
import 'package:qr_origin/pipeline/gravity_aligner.dart';
import 'package:qr_origin/pipeline/origin_verifier.dart';

/// Controls the full QR scan flow state machine.
///
/// Integrates all pipeline stages:
/// 1. Angle gate (Phase 2)
/// 2. Frame collection with temporal coherence (Phase 3)
/// 3. Multi-frame averaging with eigenvalue method (Phase 3)
/// 4. Gravity alignment with validation (Phase 4)
/// 5. Persistent storage with cross-session comparison (Phase 5)
/// 6. Automated + visual verification (Phase 6)
///
/// State flow:
///   SCANNING → COLLECTING → AVERAGING → VERIFYING → LOCKED
///       ↑                                      |
///       └──────────── (reject) ────────────────┘
class ScanController extends ChangeNotifier {
  final ArServiceInterface _arService;
  final OriginStorageService? _storageService;
  final AngleGate _angleGate;
  final FrameCollector _frameCollector;
  final OriginVerifier _verifier;

  // Configuration
  static const double maxReprojectionError = 3.0;
  static const double minConfidence = 0.5;

  // State
  ScanState _state = ScanState.scanning;
  WorldOrigin? _origin;
  AveragingResult? _averagingResult;
  GravityAlignmentResult? _gravityResult;
  VerificationReport? _verificationReport;
  OriginComparison? _previousComparison;
  String _statusMessage = 'Point camera at QR code';

  // Gravity history for averaging
  final List<Vector3> _gravityHistory = [];
  static const int _maxGravityHistory = 30;

  // Debug info
  AngleGateResult? _lastAngleResult;
  FrameCollectionResult? _lastCollectionResult;
  double _lastReprojError = 0.0;
  int _totalFramesReceived = 0;

  StreamSubscription<PoseFrame>? _frameSub;

  ScanController({
    required ArServiceInterface arService,
    OriginStorageService? storageService,
    AngleGate? angleGate,
    FrameCollector? frameCollector,
    OriginVerifier? verifier,
  })  : _arService = arService,
        _storageService = storageService,
        _angleGate = angleGate ?? AngleGate(),
        _frameCollector = frameCollector ?? FrameCollector(),
        _verifier = verifier ?? OriginVerifier.defaultIntrinsics();

  // --- Public Getters ---

  ScanState get state => _state;
  WorldOrigin? get origin => _origin;
  AveragingResult? get averagingResult => _averagingResult;
  GravityAlignmentResult? get gravityResult => _gravityResult;
  VerificationReport? get verificationReport => _verificationReport;
  OriginComparison? get previousComparison => _previousComparison;
  String get statusMessage => _statusMessage;

  // Progress
  double get progress => _frameCollector.progress;
  int get acceptedFrames => _frameCollector.acceptedCount;
  int get rejectedFrames => _frameCollector.rejectedCount;
  int get totalFramesReceived => _totalFramesReceived;

  // Angle gate
  AngleGateResult? get lastAngleResult => _lastAngleResult;
  double get lastAngleScore => _lastAngleResult?.dotProduct ?? 0.0;
  double get lastApproachAngle => _lastAngleResult?.approachAngleDeg ?? 90.0;
  AngleCorrectionHint get correctionHint =>
      _lastAngleResult?.hint ?? AngleCorrectionHint.faceDirectly;

  // Frame collector
  double get positionStdDev => _frameCollector.positionStdDev;
  double get spatialSpread => _frameCollector.spatialSpread;
  double get lastReprojError => _lastReprojError;
  FrameCollectionResult? get lastCollectionResult => _lastCollectionResult;

  // Quality
  double get confidence => _averagingResult?.confidence ?? 0.0;

  // --- Lifecycle ---

  Future<void> startSession() async {
    await _arService.initialize();
    _frameSub = _arService.poseFrameStream.listen(_onFrameReceived);
    _setState(ScanState.scanning);
    _statusMessage = 'Point camera at QR code';
    notifyListeners();
  }

  // --- Frame Processing ---

  void _onFrameReceived(PoseFrame frame) {
    _totalFramesReceived++;
    _lastReprojError = frame.reprojectionError;

    // Collect gravity samples continuously
    final gravity = _arService.lastGravityVector;
    if (gravity != null) {
      _gravityHistory.add(Vector3.copy(gravity));
      if (_gravityHistory.length > _maxGravityHistory) {
        _gravityHistory.removeAt(0);
      }
    }

    // Always evaluate angle gate for UI feedback
    final isCollecting = _state == ScanState.collecting;
    _lastAngleResult = _angleGate.evaluateFromScore(
      frame.angleScore,
      isCurrentlyCollecting: isCollecting,
    );

    switch (_state) {
      case ScanState.scanning:
        _handleScanning(frame);
        break;
      case ScanState.collecting:
        _handleCollecting(frame);
        break;
      case ScanState.averaging:
      case ScanState.verifying:
      case ScanState.locked:
        break;
    }

    notifyListeners();
  }

  void _handleScanning(PoseFrame frame) {
    if (!_lastAngleResult!.passes) {
      _statusMessage = _getAngleFeedback();
      return;
    }
    if (frame.reprojectionError > maxReprojectionError) {
      _statusMessage = 'Move closer or hold steadier '
          '(error: ${frame.reprojectionError.toStringAsFixed(1)}px)';
      return;
    }

    _setState(ScanState.collecting);
    _lastCollectionResult = _frameCollector.addFrame(frame);
    _statusMessage = 'Hold steady... collecting frames';
  }

  void _handleCollecting(PoseFrame frame) {
    if (!_lastAngleResult!.passes) {
      _statusMessage = _getAngleFeedback();
      return;
    }
    if (frame.reprojectionError > maxReprojectionError) {
      _statusMessage = 'Hold steadier... '
          '(error: ${frame.reprojectionError.toStringAsFixed(1)}px)';
      return;
    }

    _lastCollectionResult = _frameCollector.addFrame(frame);

    if (!_lastCollectionResult!.passes) {
      _statusMessage = 'Frame skipped: ${_lastCollectionResult!.reason}';
      return;
    }

    final pct = (_frameCollector.progress * 100).toInt();
    _statusMessage = 'Collecting... $pct% '
        '(σ=${(positionStdDev * 1000).toStringAsFixed(1)}mm)';

    if (_frameCollector.isComplete) {
      _computeOrigin();
    } else if (_frameCollector.isTimedOut && _frameCollector.hasEnoughFrames) {
      _computeOrigin();
    } else if (_frameCollector.isTimedOut && !_frameCollector.hasEnoughFrames) {
      reset();
      _statusMessage = 'Timed out. Not enough good frames. Try again.';
    }
  }

  String _getAngleFeedback() {
    final result = _lastAngleResult!;
    final anglePct = (result.dotProduct * 100).toInt();
    return switch (result.hint) {
      AngleCorrectionHint.none => 'Angle OK',
      AngleCorrectionHint.tiltLeft => 'Tilt left ← ($anglePct%)',
      AngleCorrectionHint.tiltRight => 'Tilt right → ($anglePct%)',
      AngleCorrectionHint.tiltUp => 'Tilt up ↑ ($anglePct%)',
      AngleCorrectionHint.tiltDown => 'Tilt down ↓ ($anglePct%)',
      AngleCorrectionHint.faceDirectly => 'Face QR straight on ($anglePct%)',
    };
  }

  // --- Origin Computation (Phase 3 + 4) ---

  void _computeOrigin() {
    _setState(ScanState.averaging);
    _statusMessage = 'Computing origin...';
    notifyListeners();

    final frames = _frameCollector.acceptedFrames;

    // Phase 3: Multi-frame averaging with eigenvalue method
    _averagingResult = PoseAverager.computeAverage(
      frames,
      errorSigma: 1.0,
      positionSigma: 2.0,
      useEigenMethod: true,
    );

    if (_averagingResult!.confidence < minConfidence) {
      reset();
      _statusMessage = 'Low confidence '
          '(${(_averagingResult!.confidence * 100).toInt()}%). Try again.';
      notifyListeners();
      return;
    }

    // Build initial pose matrix
    var poseMatrix = Matrix4.compose(
      _averagingResult!.position,
      _averagingResult!.quaternion,
      Vector3.all(1.0),
    );

    // Phase 4: Gravity alignment with full validation
    double gravityDelta = 0.0;
    final gravityVector = _arService.lastGravityVector;
    if (gravityVector != null) {
      _gravityResult = GravityAligner.alignWithValidation(
        poseMatrix,
        gravityVector,
        gravityHistory: _gravityHistory.length >= 3 ? _gravityHistory : null,
      );

      poseMatrix = _gravityResult!.alignedMatrix;
      gravityDelta = _gravityResult!.postDeltaDeg;

      debugPrint('[Gravity] Pre: ${_gravityResult!.preDeltaDeg.toStringAsFixed(2)}° '
          '→ Post: ${_gravityResult!.postDeltaDeg.toStringAsFixed(2)}° '
          '| Heading Δ: ${_gravityResult!.headingChangeDeg.toStringAsFixed(2)}° '
          '| Reliable: ${_gravityResult!.gravityReliable} '
          '| Mag: ${_gravityResult!.gravityMagnitude.toStringAsFixed(3)}');
    }

    // Build final origin
    final avgError = frames.fold<double>(
            0.0, (sum, f) => sum + f.reprojectionError) /
        frames.length;

    _origin = WorldOrigin(
      poseMatrix: poseMatrix,
      qrId: _arService.detectedQrId ?? 'unknown',
      timestamp: DateTime.now(),
      frameCount: _averagingResult!.usedFrameCount,
      avgReprojectionError: avgError,
      confidence: _averagingResult!.confidence,
      gravityDeltaDeg: gravityDelta,
      positionStdDev: _averagingResult!.positionStdDev,
    );

    // Phase 6: Run automated verification
    _verificationReport = _verifier.runAutomatedChecks(_origin!);
    debugPrint('[Verify] $_verificationReport');

    // Phase 5: Compare with previous origin (if exists)
    _loadPreviousComparison();

    _setState(ScanState.verifying);
    _statusMessage = 'Verify alignment '
        '(confidence: ${(_averagingResult!.confidence * 100).toInt()}%)';
    notifyListeners();
  }

  /// Load comparison with previously saved origin (async, non-blocking).
  Future<void> _loadPreviousComparison() async {
    if (_storageService == null || _origin == null) return;

    _previousComparison =
        await _storageService.compareWithPrevious(_origin!);

    if (_previousComparison != null) {
      debugPrint('[Storage] Comparison with previous: $_previousComparison');
    }
    notifyListeners();
  }

  // --- User Actions ---

  /// User confirms the origin is correct.
  Future<void> confirmOrigin() async {
    if (_state != ScanState.verifying || _origin == null) return;

    // Phase 5: Save to persistent storage
    if (_storageService != null) {
      await _storageService.saveOrigin(_origin!);
      debugPrint('[Storage] Origin saved for QR: ${_origin!.qrId}');
    }

    _setState(ScanState.locked);
    _statusMessage = 'Origin locked ✓ '
        '(σ=${(_origin!.positionStdDev * 1000).toStringAsFixed(2)}mm)';
    notifyListeners();
  }

  /// User rejects the origin, restart scan.
  void rejectOrigin() {
    reset();
    _statusMessage = 'Origin rejected. Scan again.';
    notifyListeners();
  }

  /// Reset to initial scanning state.
  void reset() {
    _frameCollector.reset();
    _angleGate.reset();
    _origin = null;
    _averagingResult = null;
    _gravityResult = null;
    _verificationReport = null;
    _previousComparison = null;
    _totalFramesReceived = 0;
    _lastAngleResult = null;
    _lastCollectionResult = null;
    _gravityHistory.clear();
    _setState(ScanState.scanning);
    _statusMessage = 'Point camera at QR code';
  }

  void _setState(ScanState newState) {
    _state = newState;
  }

  @override
  void dispose() {
    _frameSub?.cancel();
    _arService.dispose();
    super.dispose();
  }
}
