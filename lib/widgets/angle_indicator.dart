import 'package:flutter/material.dart';
import 'package:qr_origin/pipeline/angle_gate.dart';

/// Visual indicator showing camera approach angle quality.
///
/// Displays:
/// - Color-coded ring (green/yellow/red)
/// - Numeric angle value
/// - Directional correction arrow
class AngleIndicator extends StatelessWidget {
  final AngleGateResult? angleResult;
  final bool isCollecting;

  const AngleIndicator({
    super.key,
    required this.angleResult,
    required this.isCollecting,
  });

  @override
  Widget build(BuildContext context) {
    final result = angleResult;
    if (result == null) {
      return _buildNoData();
    }

    final color = _getColor(result);
    final angleDeg = result.approachAngleDeg;

    return Container(
      width: 180,
      height: 180,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color.withOpacity(0.8), width: 4),
        color: color.withOpacity(0.1),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Direction arrow
            _buildDirectionIcon(result.hint, color),
            const SizedBox(height: 4),

            // Angle value
            Text(
              '${angleDeg.toStringAsFixed(1)}°',
              style: TextStyle(
                color: color,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
            ),

            // Status text
            Text(
              result.passes ? 'ANGLE OK' : _getHintText(result.hint),
              style: TextStyle(
                color: color.withOpacity(0.9),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),

            // Dot product (debug-level detail)
            if (isCollecting)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'dot: ${result.dotProduct.toStringAsFixed(3)}',
                  style: TextStyle(
                    color: color.withOpacity(0.6),
                    fontSize: 9,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoData() {
    return Container(
      width: 180,
      height: 180,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white24, width: 4),
      ),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.qr_code_scanner, color: Colors.white38, size: 36),
            SizedBox(height: 8),
            Text(
              'SEARCHING...',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDirectionIcon(AngleCorrectionHint hint, Color color) {
    final iconData = switch (hint) {
      AngleCorrectionHint.none => Icons.check_circle,
      AngleCorrectionHint.tiltLeft => Icons.arrow_back,
      AngleCorrectionHint.tiltRight => Icons.arrow_forward,
      AngleCorrectionHint.tiltUp => Icons.arrow_upward,
      AngleCorrectionHint.tiltDown => Icons.arrow_downward,
      AngleCorrectionHint.faceDirectly => Icons.center_focus_strong,
    };

    return Icon(iconData, color: color, size: 36);
  }

  String _getHintText(AngleCorrectionHint hint) {
    return switch (hint) {
      AngleCorrectionHint.none => 'PERFECT',
      AngleCorrectionHint.tiltLeft => 'TILT LEFT ←',
      AngleCorrectionHint.tiltRight => 'TILT RIGHT →',
      AngleCorrectionHint.tiltUp => 'TILT UP ↑',
      AngleCorrectionHint.tiltDown => 'TILT DOWN ↓',
      AngleCorrectionHint.faceDirectly => 'FACE DIRECTLY',
    };
  }

  Color _getColor(AngleGateResult result) {
    if (result.passes) return Colors.green;
    if (result.approachAngleDeg < 30) return Colors.orange;
    return Colors.red;
  }
}
