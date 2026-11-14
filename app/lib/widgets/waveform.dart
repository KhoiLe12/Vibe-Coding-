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
    this.revision = 0,
  });

  /// Shaded spans behind the waveform, as fractions of the window (0..1):
  /// loop selection, or the visible window on an overview strip.
  final List<({double from, double to, Color color})> bands;

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

    if (playhead != null) {
      final px = playhead!.clamp(0.0, 1.0) * size.width;
      canvas.drawRect(
        Rect.fromLTWH(px - 1, 0, 2, size.height),
        Paint()..color = playheadColor ?? Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(WaveformPainter old) =>
      old.revision != revision ||
      old.minMax != minMax ||
      old.firstBlock != firstBlock ||
      old.blockCount != blockCount ||
      old.playhead != playhead ||
      !listEquals(old.bands, bands) ||
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
