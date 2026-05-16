import 'package:flutter/material.dart';
import 'package:qr_origin/controllers/scan_controller.dart';

/// Comprehensive debug panel showing all pipeline metrics in real-time.
///
/// Sections:
/// - State machine
/// - Angle gate (dot product, approach angle, correction hint)
/// - Frame collector (accepted/rejected, temporal jumps, spatial cluster)
/// - Position stability (std dev, spread)
/// - Gravity alignment (pre/post delta, heading preservation, IMU reliability)
/// - Averaging quality (confidence, rotation spread, acceptance ratio)
/// - Verification checks (automated pass/fail)
/// - Cross-session comparison (position/rotation delta vs previous)
class DebugOverlay extends StatelessWidget {
  final ScanController controller;

  const DebugOverlay({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 230,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.92),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.amber.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // State
          _header('STATE'),
          _row('Machine', controller.state.name.toUpperCase()),

          const SizedBox(height: 6),
          _header('ANGLE GATE'),
          _row('Dot Product', controller.lastAngleScore.toStringAsFixed(4)),
          _row('Approach', '${controller.lastApproachAngle.toStringAsFixed(1)}°'),
          _row('Hint', controller.correctionHint.name),

          const SizedBox(height: 6),
          _header('FRAMES'),
          _row('Total', '${controller.totalFramesReceived}'),
          _row('Accepted', '${controller.acceptedFrames}'),
          _row('Rejected', '${controller.rejectedFrames}'),
          _row('Progress', '${(controller.progress * 100).toInt()}%'),

          const SizedBox(height: 6),
          _header('STABILITY'),
          _row('Pos σ', '${(controller.positionStdDev * 1000).toStringAsFixed(2)} mm'),
          _row('Spread', '${(controller.spatialSpread * 1000).toStringAsFixed(2)} mm'),
          _row('Reproj', '${controller.lastReprojError.toStringAsFixed(2)} px'),

          // Gravity (after computation)
          if (controller.gravityResult != null) ...[
            const SizedBox(height: 6),
            _header('GRAVITY'),
            _row('Pre Δ',
                '${controller.gravityResult!.preDeltaDeg.toStringAsFixed(2)}°'),
            _row('Post Δ',
                '${controller.gravityResult!.postDeltaDeg.toStringAsFixed(3)}°'),
            _row('Heading Δ',
                '${controller.gravityResult!.headingChangeDeg.toStringAsFixed(2)}°'),
            _row('IMU OK',
                controller.gravityResult!.gravityReliable ? 'Yes' : 'No'),
            _row('Mag',
                '${controller.gravityResult!.gravityMagnitude.toStringAsFixed(3)}'),
          ],

          // Averaging (after computation)
          if (controller.averagingResult != null) ...[
            const SizedBox(height: 6),
            _header('AVERAGING'),
            _row('Confidence', '${(controller.confidence * 100).toInt()}%'),
            _row('Pos σ (final)',
                '${(controller.averagingResult!.positionStdDev * 1000).toStringAsFixed(2)} mm'),
            _row('Rot Spread',
                '${controller.averagingResult!.rotationSpreadDeg.toStringAsFixed(2)}°'),
            _row('Used', '${controller.averagingResult!.usedFrameCount} frames'),
            _row('Accept%',
                '${(controller.averagingResult!.acceptanceRatio * 100).toInt()}%'),
          ],

          // Verification
          if (controller.verificationReport != null) ...[
            const SizedBox(height: 6),
            _header('VERIFICATION'),
            _row('Checks',
                '${controller.verificationReport!.passedCount}/${controller.verificationReport!.totalCount} passed'),
            _row('Status',
                controller.verificationReport!.allPassed ? '✓ ALL OK' : '✗ FAILED'),
          ],

          // Cross-session comparison
          if (controller.previousComparison != null) ...[
            const SizedBox(height: 6),
            _header('VS PREVIOUS'),
            _row('Pos Δ',
                '${controller.previousComparison!.positionDiffMm.toStringAsFixed(2)} mm'),
            _row('Rot Δ',
                '${controller.previousComparison!.rotationDiffDeg.toStringAsFixed(2)}°'),
            _row('Consistent',
                controller.previousComparison!.isConsistent ? '✓' : '✗'),
          ],

          // Origin info
          if (controller.origin != null) ...[
            const SizedBox(height: 6),
            _header('ORIGIN'),
            _row('QR', controller.origin!.qrId),
            _row('Gravity Δ',
                '${controller.origin!.gravityDeltaDeg.toStringAsFixed(3)}°'),
          ],
        ],
      ),
    );
  }

  Widget _header(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2, top: 2),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.amber,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 10),
            ),
          ),
          Flexible(
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
