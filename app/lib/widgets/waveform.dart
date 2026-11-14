// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Draws min/max peaks (wiki/components/waveform-view.md,
// wiki/concepts/waveform-rendering.md): one vertical bar per pixel column,
// aggregated from the cached peaks — never from raw samples.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class WaveformPainter extends CustomPainter {
  WaveformPainter({
    required this.minMax,
    required this.firstBlock,
    required this.blockCount,
    required this.color,
    this.playhead,
    this.playheadColor,
    this.bands = const [],
    this.markers = const [],
    this.markerColor,
    this.revision = 0,
    this.fades,
    this.fadeColor,
    this.handleSize = 18,
    this.gridLines = const [],
    this.gridColor,
  });

  /// Beat grid (M5b): lines as fractions of the window; bar lines
  /// stronger.
  final List<({double at, bool bar})> gridLines;
  final Color? gridColor;

  /// Fade handles (M7) on a region (the take or a selection), as fractions
  /// of the window: the region [from]–[to], and where the fade in reaches
  /// full volume ([inEnd]) and the fade out starts ([outStart]). Draws each
  /// fade's curve and a square handle in the top corner; [active] is the
  /// handle being dragged (true = fade in), drawn larger.
  final ({double from, double inEnd, double outStart, double to, bool? active})?
  fades;
  final Color? fadeColor;
  final double handleSize;

  /// Shaded spans behind the waveform, as fractions of the window (0..1):
  /// loop selection, or the visible window on an overview strip.
  final List<({double from, double to, Color color})> bands;

  /// Thin vertical lines (fractions of the window), e.g. clip joins.
  final List<double> markers;
  final Color? markerColor;

  /// Interleaved (min, max) pairs.
  final Float32List minMax;

  /// Visible window, in blocks. Blocks beyond the data draw as empty, so a
  /// live recording fills from the left.
  final int firstBlock;
  final int blockCount;
  final Color color;

  /// Playhead position as a fraction of the window (0..1).
  final double? playhead;
  final Color? playheadColor;

  /// Bump when [minMax] grows in place, to force a repaint.
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    for (final b in bands) {
      final l = b.from.clamp(0.0, 1.0) * size.width;
      final r = b.to.clamp(0.0, 1.0) * size.width;
      if (r > l) {
        canvas.drawRect(
          Rect.fromLTRB(l, 0, r, size.height),
          Paint()..color = b.color,
        );
      }
    }
    if (gridLines.isNotEmpty) {
      final c = gridColor ?? color;
      final beat = Paint()..color = c.withValues(alpha: 0.12);
      final bar = Paint()..color = c.withValues(alpha: 0.35);
      for (final g in gridLines) {
        if (g.at < 0 || g.at > 1) continue;
        final x = g.at * size.width;
        canvas.drawRect(
          Rect.fromLTWH(x - 0.5, 0, g.bar ? 1.5 : 1, size.height),
          g.bar ? bar : beat,
        );
      }
    }
    final mid = size.height / 2;
    final half = size.height / 2 * 0.95;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, mid),
      Offset(size.width, mid),
      paint..color = color.withValues(alpha: 0.35),
    );
    paint.color = color;

    final available = minMax.length ~/ 2;
    final columns = size.width.floor();
    if (columns <= 0 || blockCount <= 0) return;
    final blocksPerColumn = blockCount / columns;
    for (var x = 0; x < columns; x++) {
      final from = firstBlock + (x * blocksPerColumn).floor();
      final to = math.max(
        from + 1,
        firstBlock + ((x + 1) * blocksPerColumn).floor(),
      );
      if (from >= available) break;
      var lo = 1.0, hi = -1.0;
      for (var b = from; b < to && b < available; b++) {
        lo = math.min(lo, minMax[2 * b]);
        hi = math.max(hi, minMax[2 * b + 1]);
      }
      lo = lo.clamp(-1.0, 1.0);
      hi = hi.clamp(-1.0, 1.0);
      final top = mid - hi * half, bottom = mid - lo * half;
      canvas.drawRect(
        Rect.fromLTRB(x.toDouble(), top, x + 1.0, math.max(bottom, top + 1)),
        paint,
      );
    }

    final markerPaint = Paint()..color = markerColor ?? color;
    for (final m in markers) {
      if (m < 0 || m > 1) continue;
      final x = m * size.width;
      canvas.drawRect(Rect.fromLTWH(x - 0.5, 0, 1, size.height), markerPaint);
    }

    final f = fades;
    if (f != null) {
      final c = fadeColor ?? Colors.orange;
      final w = size.width;
      _drawFade(canvas, size, c, f.from * w, f.inEnd * w);
      _drawFade(canvas, size, c, f.to * w, f.outStart * w);
      _drawHandle(
        canvas,
        c,
        f.inEnd * w,
        fadeIn: true,
        active: f.active == true,
      );
      _drawHandle(
        canvas,
        c,
        f.outStart * w,
        fadeIn: false,
        active: f.active == false,
      );
    }

    if (playhead != null) {
      final px = playhead!.clamp(0.0, 1.0) * size.width;
      canvas.drawRect(
        Rect.fromLTWH(px - 1, 0, 2, size.height),
        Paint()..color = playheadColor ?? Colors.white,
      );
    }
  }

  /// A fade from silence at [edge] to full at [full] (pixels): shaded, with
  /// its gain curve drawn top (full) to bottom (silent).
  void _drawFade(Canvas canvas, Size size, Color c, double edge, double full) {
    if ((full - edge).abs() < 0.5) return;
    canvas.drawRect(
      Rect.fromLTRB(math.min(edge, full), 0, math.max(edge, full), size.height),
      Paint()..color = c.withValues(alpha: 0.15),
    );
    final path = Path();
    const steps = 48;
    for (var i = 0; i <= steps; i++) {
      final u = i / steps; // 0 at the edge, 1 where it is full
      final s = math.sin(u * math.pi / 2);
      final y = size.height * (1 - s * s);
      final x = edge + (full - edge) * u;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = c
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  /// A square handle hanging from the top at [x]: right of it for a fade in,
  /// left of it for a fade out, so at the region's edges both stay inside.
  void _drawHandle(
    Canvas canvas,
    Color c,
    double x, {
    required bool fadeIn,
    required bool active,
  }) {
    final s = active ? handleSize * 1.3 : handleSize;
    final rect = fadeIn
        ? Rect.fromLTWH(x, 0, s, s)
        : Rect.fromLTWH(x - s, 0, s, s);
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        rect,
        bottomLeft: fadeIn ? Radius.zero : const Radius.circular(4),
        bottomRight: fadeIn ? const Radius.circular(4) : Radius.zero,
      ),
      Paint()..color = c,
    );
    canvas.drawRect(Rect.fromLTWH(x - 1, 0, 2, s * 1.6), Paint()..color = c);
  }

  @override
  bool shouldRepaint(WaveformPainter old) =>
      old.revision != revision ||
      old.minMax != minMax ||
      old.firstBlock != firstBlock ||
      old.blockCount != blockCount ||
      old.playhead != playhead ||
      !listEquals(old.bands, bands) ||
      !listEquals(old.markers, markers) ||
      !listEquals(old.gridLines, gridLines) ||
      old.fades != fades ||
      old.color != color;
}

/// Input level meter in dBFS (−60 … 0) with a clip light.
class LevelMeter extends StatelessWidget {
  const LevelMeter({
    super.key,
    required this.peak,
    required this.clipped,
    required this.onResetClip,
  });

  /// Linear peak, 0..1+.
  final double peak;
  final bool clipped;
  final VoidCallback onResetClip;

  static double toDb(double linear) =>
      linear <= 1e-6 ? -120 : 20 * math.log(linear) / math.ln10;

  @override
  Widget build(BuildContext context) {
    final db = toDb(peak);
    final fill = ((db + 60) / 60).clamp(0.0, 1.0);
    final color = db > -3
        ? Colors.red
        : db > -12
        ? Colors.amber
        : Colors.green;
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 14,
              child: Stack(
                children: [
                  Container(color: scheme.surfaceContainerHighest),
                  FractionallySizedBox(
                    widthFactor: fill,
                    child: Container(color: color),
                  ),
                  // −6 dBFS headroom mark (recording-diverse-material).
                  Align(
                    alignment: const Alignment((54 / 60) * 2 - 1, 0),
                    child: Container(width: 2, color: scheme.onSurface),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: 'Clip indicator — tap to reset',
          child: GestureDetector(
            key: const Key('clip'),
            onTap: onResetClip,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: clipped ? Colors.red : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'CLIP',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: clipped ? Colors.white : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

String formatDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}
