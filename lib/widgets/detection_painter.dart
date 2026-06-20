import 'package:flutter/material.dart';
import '../services/inference_service.dart';

class DetectionPainter extends CustomPainter {
  final List<InferenceResult> detections;
  final Size imageSize;
  final Size screenSize;

  DetectionPainter({
    required this.detections,
    required this.imageSize,
    required this.screenSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (detections.isEmpty) return;

    // Debug: Print bbox format untuk verify
    if (detections.isNotEmpty) {
      debugPrint('🎯 DetectionPainter.paint() called');
      debugPrint('   Canvas size: ${size.width}x${size.height}');
      debugPrint('   Image size: ${imageSize.width}x${imageSize.height}');
      debugPrint('   Detection count: ${detections.length}');
      debugPrint('   First detection bbox: ${detections[0].bbox}');
      debugPrint('   First detection label: ${detections[0].label}');
    }

    for (final det in detections) {
      try {
        final color = _colorForLabel(det.label);
        final paint = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5;

        // ✅ FIX #1: Proper bbox format handling
        // bbox format: [x1, y1, x2, y2] (top-left, bottom-right) OR [cx, cy, w, h] (center format)
        // Let's handle both:

        late Rect rect;

        if (det.bbox.length == 4) {
          final x1 = det.bbox[0];
          final y1 = det.bbox[1];
          final x2 = det.bbox[2];
          final y2 = det.bbox[3];

          // Check if it's center format (cx, cy, w, h) or corner format (x1, y1, x2, y2)
          // If x2 > x1 and y2 > y1, it's corner format
          // Otherwise assume center format

          if (x2 > x1 && y2 > y1 && x2 < 1.5 && y2 < 1.5) {
            // Corner format (x1, y1, x2, y2) — normalized [0, 1]
            final x = x1 * size.width;
            final y = y1 * size.height;
            final w = (x2 - x1) * size.width;
            final h = (y2 - y1) * size.height;
            rect = Rect.fromLTWH(x, y, w, h);

            debugPrint('   ✅ Bbox format: CORNER (x1, y1, x2, y2) normalized');
          } else if (x1 > 1 && y1 > 1) {
            // Corner format (x1, y1, x2, y2) — pixel coords
            final x = x1;
            final y = y1;
            final w = x2 - x1;
            final h = y2 - y1;
            rect = Rect.fromLTWH(x, y, w, h);

            debugPrint('   ✅ Bbox format: CORNER (pixel coords)');
          } else {
            // Center format (cx, cy, w, h) — original logic
            final scaleX = size.width / 640;
            final scaleY = size.height / 640;

            final x = (x1 - x2 / 2) * scaleX;
            final y = (y1 - y2 / 2) * scaleY;
            final w = x2 * scaleX;
            final h = y2 * scaleY;
            rect = Rect.fromLTWH(x, y, w, h);

            debugPrint('   ✅ Bbox format: CENTER (cx, cy, w, h)');
          }
        } else {
          debugPrint('   ⚠️  Unexpected bbox format: ${det.bbox.length} elements');
          continue;
        }

        // ✅ FIX #2: Clamp rect to canvas bounds
        final clampedRect = rect.intersect(Offset.zero & size);

        if (clampedRect.isEmpty) {
          debugPrint('   ⚠️  Detection outside canvas bounds, skipping');
          continue;
        }

        // Draw rounded rectangle
        canvas.drawRRect(
          RRect.fromRectAndRadius(clampedRect, const Radius.circular(6)),
          paint,
        );

        // ✅ FIX #3: Better label rendering
        final labelText =
            '${det.label.toUpperCase()} ${(det.confidence * 100).toStringAsFixed(0)}%';
        final textPainter = TextPainter(
          text: TextSpan(
            text: ' $labelText ',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

        // Label position — prefer top, fallback to bottom if too close to edge
        final labelY = clampedRect.top > 20
            ? clampedRect.top - textPainter.height - 4
            : clampedRect.bottom + 4;

        // Draw label background
        final labelBgPaint = Paint()
          ..color = color.withOpacity(0.85)
          ..style = PaintingStyle.fill;

        final labelBgRect = Rect.fromLTWH(
          clampedRect.left,
          labelY,
          textPainter.width,
          textPainter.height,
        ).inflate(2); // Add padding

        canvas.drawRRect(
          RRect.fromRectAndRadius(labelBgRect, const Radius.circular(3)),
          labelBgPaint,
        );

        // Draw label text
        textPainter.paint(canvas, Offset(labelBgRect.left + 2, labelY));

        debugPrint(
            '   ✓ Drawn: $labelText @ (${clampedRect.left.toStringAsFixed(1)}, ${clampedRect.top.toStringAsFixed(1)})');
      } catch (e) {
        debugPrint('   ❌ Error painting detection: $e');
      }
    }
  }

  Color _colorForLabel(String label) {
    final l = label.toLowerCase();
    if (l.contains('stachybotrys') || l.contains('black')) {
      return const Color(0xFFFF4444); // red
    }
    if (l.contains('aspergillus') || l.contains('green')) {
      return const Color(0xFF00C896); // green
    }
    if (l.contains('cladosporium') || l.contains('brown')) {
      return const Color(0xFFFFAA00); // orange
    }
    return const Color(0xFF00C896);
  }

  @override
  bool shouldRepaint(DetectionPainter oldDelegate) {
    // ✅ FIX #4: Better list comparison
    if (oldDelegate.detections.length != detections.length) return true;

    for (int i = 0; i < detections.length; i++) {
      if (oldDelegate.detections[i].label != detections[i].label ||
          (oldDelegate.detections[i].confidence - detections[i].confidence)
                  .abs() >
              0.01) {
        return true;
      }
    }

    return false;
  }
}