import 'dart:ui';

/// Raw QR detection result per frame — normalized screen-space corners.
/// Coordinates are normalized (0..1) relative to screen dimensions.
class QrDetection {
  /// 4 corner points of QR in normalized screen coordinates (0..1).
  /// Order: top-left, top-right, bottom-right, bottom-left.
  final List<Offset> corners;

  /// Timestamp.
  final int timestampMs;

  QrDetection({
    required this.corners,
    required this.timestampMs,
  });

  /// Center of QR in normalized coordinates.
  Offset get center => Offset(
    (corners[0].dx + corners[1].dx + corners[2].dx + corners[3].dx) / 4,
    (corners[0].dy + corners[1].dy + corners[2].dy + corners[3].dy) / 4,
  );

  /// Convert normalized corners to pixel coordinates for given screen size.
  List<Offset> toPixels(Size screenSize) {
    return corners.map((c) => Offset(
      c.dx * screenSize.width,
      c.dy * screenSize.height,
    )).toList();
  }

  Offset centerPixels(Size screenSize) {
    final c = center;
    return Offset(c.dx * screenSize.width, c.dy * screenSize.height);
  }
}
