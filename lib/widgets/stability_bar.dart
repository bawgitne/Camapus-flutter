import 'package:flutter/material.dart';

/// Visual bar showing position stability during frame collection.
///
/// Shows two metrics:
/// - Position standard deviation (how much the detected pose jitters)
/// - Spatial spread (max distance from centroid)
///
/// Green = excellent (<1mm), Yellow = acceptable (<3mm), Red = poor
class StabilityBar extends StatelessWidget {
  final double positionStdDev; // meters
  final double spatialSpread; // meters

  const StabilityBar({
    super.key,
    required this.positionStdDev,
    required this.spatialSpread,
  });

  @override
  Widget build(BuildContext context) {
    final stdDevMm = positionStdDev * 1000;
    final spreadMm = spatialSpread * 1000;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.75),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          // Stability icon
          Icon(
            _getStabilityIcon(stdDevMm),
            color: _getColor(stdDevMm),
            size: 20,
          ),
          const SizedBox(width: 10),

          // Std dev
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Jitter: ${stdDevMm.toStringAsFixed(2)} mm',
                  style: TextStyle(
                    color: _getColor(stdDevMm),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                // Progress bar representing stability
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: (1.0 - (stdDevMm / 5.0)).clamp(0.0, 1.0),
                    backgroundColor: Colors.white12,
                    valueColor: AlwaysStoppedAnimation(_getColor(stdDevMm)),
                    minHeight: 4,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 16),

          // Spread
          Text(
            'Spread: ${spreadMm.toStringAsFixed(1)}mm',
            style: TextStyle(
              color: _getColor(spreadMm),
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  Color _getColor(double valueMm) {
    if (valueMm < 1.0) return Colors.green;
    if (valueMm < 3.0) return Colors.orange;
    return Colors.red;
  }

  IconData _getStabilityIcon(double stdDevMm) {
    if (stdDevMm < 1.0) return Icons.straighten;
    if (stdDevMm < 3.0) return Icons.vibration;
    return Icons.warning;
  }
}
