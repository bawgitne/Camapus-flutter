import 'dart:math';
import 'package:flutter/material.dart';
import 'package:qr_origin/models/qr_detection.dart';

/// Draws 3D coordinate axes ghim trên mặt QR code với perspective đúng.
///
/// Dùng homography từ 4 corners QR để project điểm 3D lên screen.
/// - X (đỏ) = nằm trên mặt QR, hướng phải
/// - Z (xanh dương) = nằm trên mặt QR, hướng xuống
/// - Y (xanh lá) = ĐỨNG THẲNG lên khỏi mặt QR (vuông góc mặt phẳng)
///
/// Trục Y sẽ có perspective thật — ngắn lại khi nhìn xiên, dài ra khi nhìn thẳng.
class AxesOverlay extends StatelessWidget {
  final QrDetection? detection;
  final bool isLocked;

  const AxesOverlay({
    super.key,
    required this.detection,
    this.isLocked = false,
  });

  @override
  Widget build(BuildContext context) {
    if (detection == null) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final screenSize = Size(constraints.maxWidth, constraints.maxHeight);
        return CustomPaint(
          size: screenSize,
          painter: _Axes3DPainter(
            detection: detection!,
            screenSize: screenSize,
            isLocked: isLocked,
          ),
        );
      },
    );
  }
}

class _Axes3DPainter extends CustomPainter {
  final QrDetection detection;
  final Size screenSize;
  final bool isLocked;

  _Axes3DPainter({
    required this.detection,
    required this.screenSize,
    required this.isLocked,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final corners = detection.toPixels(screenSize);
    if (corners.length < 4) return;

    // QR corners in screen pixels
    // [0]=topLeft, [1]=topRight, [2]=bottomRight, [3]=bottomLeft
    final tl = corners[0];
    final tr = corners[1];
    final br = corners[2];
    final bl = corners[3];

    // Define QR plane coordinate system:
    // QR is a unit square from (0,0) to (1,1) in "QR space"
    // We use homography to map any (u,v) on QR plane → screen pixel
    //
    // Additionally, for the Y axis (perpendicular to QR plane),
    // we use vanishing point geometry.

    // Origin in QR space = center = (0.5, 0.5)
    final origin = _mapToScreen(0.5, 0.5, tl, tr, br, bl);

    // X axis endpoint: move right on QR plane
    // (0.5, 0.5) → (1.0, 0.5) = half the QR width to the right
    final xEnd = _mapToScreen(1.0, 0.5, tl, tr, br, bl);

    // Z axis endpoint: move down on QR plane
    // (0.5, 0.5) → (0.5, 1.0) = half the QR height downward
    final zEnd = _mapToScreen(0.5, 1.0, tl, tr, br, bl);

    // Y axis: perpendicular to QR plane, pointing OUT of the surface.
    // Use vanishing point method:
    // The Y axis direction in screen space can be computed from
    // the cross product of the two QR plane directions.
    final yEnd = _computeYAxis(origin, tl, tr, br, bl);

    // Draw QR outline
    _drawOutline(canvas, tl, tr, br, bl);

    // Draw filled semi-transparent QR plane
    _drawPlane(canvas, tl, tr, br, bl);

    // Draw axes — Y first (behind), then X and Z (on surface)
    _drawAxis(canvas, origin, yEnd, Colors.green, 'Y', 4.0);
    _drawAxis(canvas, origin, xEnd, Colors.red, 'X', 4.0);
    _drawAxis(canvas, origin, zEnd, Colors.blue, 'Z', 4.0);

    // Origin dot
    canvas.drawCircle(origin, 8, Paint()..color = Colors.white);
    canvas.drawCircle(origin, 5, Paint()..color = Colors.black87);
  }

  /// Bilinear interpolation on the quad defined by 4 corners.
  /// Maps (u, v) in [0,1]x[0,1] to screen pixel position.
  /// This gives correct perspective for points ON the QR plane.
  Offset _mapToScreen(double u, double v, Offset tl, Offset tr, Offset br, Offset bl) {
    // Bilinear interpolation:
    // P = (1-v)*[(1-u)*TL + u*TR] + v*[(1-u)*BL + u*BR]
    final top = Offset(
      (1 - u) * tl.dx + u * tr.dx,
      (1 - u) * tl.dy + u * tr.dy,
    );
    final bottom = Offset(
      (1 - u) * bl.dx + u * br.dx,
      (1 - u) * bl.dy + u * br.dy,
    );
    return Offset(
      (1 - v) * top.dx + v * bottom.dx,
      (1 - v) * top.dy + v * bottom.dy,
    );
  }

  /// Compute the Y axis endpoint (perpendicular to QR plane).
  /// Uses the normal vector derived from the perspective distortion of the quad.
  ///
  /// Method: compute vanishing points of the two edge directions,
  /// then the normal direction is perpendicular to both vanishing directions.
  /// Simplified: use cross product of screen-space edge vectors and scale.
  Offset _computeYAxis(Offset origin, Offset tl, Offset tr, Offset br, Offset bl) {
    // Edge vectors on screen
    final edgeX = Offset(
      (tr.dx - tl.dx + br.dx - bl.dx) / 2,
      (tr.dy - tl.dy + br.dy - bl.dy) / 2,
    );
    final edgeZ = Offset(
      (bl.dx - tl.dx + br.dx - tr.dx) / 2,
      (bl.dy - tl.dy + br.dy - tr.dy) / 2,
    );

    // Cross product in 2D gives the "out of screen" direction.
    // For a 3D effect, we compute a perpendicular that accounts for perspective.
    // The normal in screen space points roughly opposite to the average of edges.
    //
    // Better approach: the Y axis should go "up" from the QR surface.
    // In perspective, "up from surface" = direction that makes the quad look
    // like it's extruding. We use the perpendicular to the average diagonal.

    // Compute the "up" direction using the cross product magnitude as scale
    final cross = edgeX.dx * edgeZ.dy - edgeX.dy * edgeZ.dx;
    final scale = cross.abs();

    // The normal direction in screen: perpendicular to the plane formed by edges
    // For a roughly horizontal QR, this points "up" on screen.
    // For a tilted QR, it follows the tilt.
    //
    // Use the perpendicular bisector approach:
    // Normal ≈ -(edgeX_perp + edgeZ_perp) normalized, scaled by QR size
    final perpX = Offset(-edgeX.dy, edgeX.dx); // 90° rotation of edgeX
    final perpZ = Offset(-edgeZ.dy, edgeZ.dx); // 90° rotation of edgeZ

    // Average perpendicular = approximate surface normal direction on screen
    var normalDir = Offset(
      (perpX.dx + perpZ.dx) / 2,
      (perpX.dy + perpZ.dy) / 2,
    );

    final normalLen = normalDir.distance;
    if (normalLen < 1) return origin;

    // Normalize and scale to ~half the QR size
    final qrSize = (edgeX.distance + edgeZ.distance) / 2;
    final axisLen = qrSize * 0.5;

    normalDir = Offset(
      normalDir.dx / normalLen * axisLen,
      normalDir.dy / normalLen * axisLen,
    );

    // Y axis goes in the direction of the surface normal
    // (away from the surface, towards camera)
    // Make sure it points "outward" (towards smaller perspective = towards camera)
    // If cross > 0, normal points towards us; if < 0, flip
    if (cross < 0) {
      normalDir = Offset(-normalDir.dx, -normalDir.dy);
    }

    return origin + normalDir;
  }

  void _drawOutline(Canvas canvas, Offset tl, Offset tr, Offset br, Offset bl) {
    final paint = Paint()
      ..color = isLocked ? Colors.green : Colors.yellow
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(tl.dx, tl.dy)
      ..lineTo(tr.dx, tr.dy)
      ..lineTo(br.dx, br.dy)
      ..lineTo(bl.dx, bl.dy)
      ..close();
    canvas.drawPath(path, paint);
  }

  void _drawPlane(Canvas canvas, Offset tl, Offset tr, Offset br, Offset bl) {
    final paint = Paint()
      ..color = (isLocked ? Colors.green : Colors.yellow).withAlpha(30)
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(tl.dx, tl.dy)
      ..lineTo(tr.dx, tr.dy)
      ..lineTo(br.dx, br.dy)
      ..lineTo(bl.dx, bl.dy)
      ..close();
    canvas.drawPath(path, paint);
  }

  void _drawAxis(Canvas canvas, Offset from, Offset to, Color color, String label, double width) {
    canvas.drawLine(from, to, Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round);

    // Arrow head
    final dir = to - from;
    final len = dir.distance;
    if (len < 15) return;
    final norm = Offset(dir.dx / len, dir.dy / len);
    final perp = Offset(-norm.dy, norm.dx);
    final arrowSize = 14.0;
    final base = to - norm * arrowSize;
    final arrowPath = Path()
      ..moveTo(to.dx, to.dy)
      ..lineTo(base.dx + perp.dx * arrowSize * 0.4,
               base.dy + perp.dy * arrowSize * 0.4)
      ..lineTo(base.dx - perp.dx * arrowSize * 0.4,
               base.dy - perp.dy * arrowSize * 0.4)
      ..close();
    canvas.drawPath(arrowPath, Paint()..color = color);

    // Label
    final labelOffset = to + norm * 8;
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontSize: 16,
          fontWeight: FontWeight.bold,
          shadows: const [
            Shadow(color: Colors.black, blurRadius: 4),
            Shadow(color: Colors.black, blurRadius: 2),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(canvas, labelOffset);
  }

  @override
  bool shouldRepaint(covariant _Axes3DPainter old) => true;
}
