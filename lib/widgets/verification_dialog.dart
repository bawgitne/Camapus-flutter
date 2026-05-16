import 'package:flutter/material.dart';
import 'package:qr_origin/pipeline/gravity_aligner.dart';
import 'package:qr_origin/pipeline/origin_verifier.dart';
import 'package:qr_origin/services/origin_storage_service.dart';

/// Verification dialog - compact version that fits on all screen sizes.
class VerificationDialog extends StatelessWidget {
  final VoidCallback onConfirm;
  final VoidCallback onReject;
  final double confidence;
  final double positionStdDev;
  final double rotationSpread;
  final GravityAlignmentResult? gravityResult;
  final VerificationReport? report;
  final OriginComparison? previousComparison;

  const VerificationDialog({
    super.key,
    required this.onConfirm,
    required this.onReject,
    required this.confidence,
    required this.positionStdDev,
    required this.rotationSpread,
    this.gravityResult,
    this.report,
    this.previousComparison,
  });

  @override
  Widget build(BuildContext context) {
    final confidencePct = (confidence * 100).toInt();
    final stdDevMm = positionStdDev * 1000;

    return Dialog(
      backgroundColor: Colors.grey.shade900,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Title
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Icon(
                    confidencePct >= 70 ? Icons.verified : Icons.warning_amber,
                    color: confidencePct >= 70 ? Colors.green : Colors.amber,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Verify Origin',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),

            // Scrollable content
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Key metrics row
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _metric('Conf', '$confidencePct%',
                              _confColor(confidencePct)),
                          _metric('σ', '${stdDevMm.toStringAsFixed(1)}mm',
                              _stdColor(stdDevMm)),
                          _metric('Rot', '${rotationSpread.toStringAsFixed(1)}°',
                              _rotColor(rotationSpread)),
                        ],
                      ),
                    ),

                    // Previous comparison (if available)
                    if (previousComparison != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: previousComparison!.isConsistent
                              ? Colors.green.withValues(alpha: 0.1)
                              : Colors.orange.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: previousComparison!.isConsistent
                                ? Colors.green
                                : Colors.orange,
                          ),
                        ),
                        child: Text(
                          previousComparison!.isConsistent
                              ? '✓ Consistent with previous (Δ${previousComparison!.positionDiffMm.toStringAsFixed(1)}mm)'
                              : '⚠ Differs from previous (Δ${previousComparison!.positionDiffMm.toStringAsFixed(1)}mm)',
                          style: TextStyle(
                            color: previousComparison!.isConsistent
                                ? Colors.green
                                : Colors.orange,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 12),
                    const Text(
                      'Does the crosshair align with the physical marker at 1m?',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),

            // Buttons - always visible at bottom
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onReject,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text('REJECT'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: onConfirm,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text('CONFIRM ✓'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 10)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(
          color: color, fontSize: 14, fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
        )),
      ],
    );
  }

  Color _confColor(int pct) =>
      pct >= 80 ? Colors.green : pct >= 60 ? Colors.orange : Colors.red;
  Color _stdColor(double mm) =>
      mm < 1.0 ? Colors.green : mm < 3.0 ? Colors.orange : Colors.red;
  Color _rotColor(double deg) =>
      deg < 0.5 ? Colors.green : deg < 1.5 ? Colors.orange : Colors.red;
}
