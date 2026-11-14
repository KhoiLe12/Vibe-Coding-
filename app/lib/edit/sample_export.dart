// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Sample tools that need the audio (M7, wiki/features/sampling-tools.md,
// wiki/decisions/d016-sampling-tools.md): export planning (one-shot, seamless
// loop, one file per clip), the work itself on a background isolate, peak
// scans for normalize, and finding where the sound is for trim silence.
//
// Everything that runs on an isolate is top-level and takes plain data, so
// no closure drags a State along ("object is unsendable", see bounce.dart).

import 'dart:isolate';
import 'dart:math' as math;

import 'package:pocket_audio/pocket_audio.dart';

import '../takes/take_store.dart' show Peaks;
import 'edit_list.dart';
import 'render_cache.dart';

/// A sample format offered for export.
class ExportFormat {
  const ExportFormat(this.sampleRate, this.bits, this.label);

  final int sampleRate;
  final ExportBits bits;
  final String label;
}

/// 48 kHz / 24-bit is the default (the app records at 48 kHz).
const exportFormats = [
  ExportFormat(48000, ExportBits.pcm24, '48 kHz · 24-bit'),
  ExportFormat(44100, ExportBits.pcm24, '44.1 kHz · 24-bit'),
  ExportFormat(44100, ExportBits.pcm16, '44.1 kHz · 16-bit'),
];

enum ExportKind { oneShot, loop, slices }

/// One file to write.
class ExportItem {
  const ExportItem(this.source, this.clips, this.output, {this.loopFrames = 0});

  final String source;
  final List<PlayClip> clips;
  final String output;
  final int loopFrames;
}

/// Audio after a loop's end that is crossfaded into its head (matches the
/// engine's kSeamFrames: 10 ms at 48 kHz, in played frames).
const loopSeamFrames = 480;

/// Clips for timeline [a, b) (edit frames) as the engine plays them: from
/// [render] when there is one (pitch/tempo/varispeed), else the recording.
List<PlayClip> clipsForRange(EditList e, int a, int b, Render? render) {
  final t = e.trim(a, b);
  return render == null
      ? [for (final c in t.clips) c.toPlay()]
      : render.clipsFor(t);
}

/// Plans the files for an export of [edits] ([range] in edit frames: the
/// selection, or null for the whole take). [source] is what the clips index
/// into (the render's path, or the recording's). Names are
/// `<dir>/<base>.wav`, `<base> loop.wav`, `<base> slice 01.wav`, ….
List<ExportItem> planExport({
  required ExportKind kind,
  required EditList edits,
  required Render? render,
  required String source,
  required String dir,
  required String base,
  ({int start, int end})? range,
}) {
  final a = range?.start ?? 0, b = range?.end ?? edits.length;
  final ratio = render?.tune.timeRatio ?? 1.0;
  switch (kind) {
    case ExportKind.oneShot:
      return [
        ExportItem(
          source,
          clipsForRange(edits, a, b, render),
          '$dir/$base.wav',
        ),
      ];
    case ExportKind.loop:
      // The audio that followed the loop (if any) makes the seam.
      final seam = (loopSeamFrames * ratio).ceil();
      return [
        ExportItem(
          source,
          clipsForRange(edits, a, math.min(edits.length, b + seam), render),
          '$dir/$base loop.wav',
          loopFrames: ((b - a) / ratio).round(),
        ),
      ];
    case ExportKind.slices:
      final out = <ExportItem>[];
      final digits = math.max(2, '${edits.clips.length}'.length);
      for (var i = 0; i < edits.clips.length; i++) {
        final s = edits.startOf(i), e = s + edits.clips[i].length;
        if (e <= a || s >= b) continue; // outside the range
        final n = '${out.length + 1}'.padLeft(digits, '0');
        out.add(
          ExportItem(
            source,
            clipsForRange(edits, math.max(a, s), math.min(b, e), render),
            '$dir/$base slice $n.wav',
          ),
        );
      }
      return out;
  }
}

/// Writes [items] on a background isolate.
Future<void> runExports(
  List<ExportItem> items,
  int sampleRate,
  ExportBits bits,
) => Isolate.run(() {
  for (final it in items) {
    PocketAudio.exportWav(
      source: it.source,
      clips: it.clips,
      output: it.output,
      sampleRate: sampleRate,
      bits: bits,
      loopFrames: it.loopFrames,
    );
  }
});

/// Loudest sample of [clips] of [source] as played (gain included; fades
/// only make it quieter). On a background isolate.
Future<double> peakOfClips(String source, List<PlayClip> clips) =>
    Isolate.run(() {
      var p = 0.0;
      for (final c in clips) {
        final v = PocketAudio.peak(source, [(start: c.start, end: c.end)]);
        p = math.max(p, v * c.gain.abs());
      }
      return p;
    });

/// Peak level that normalize brings a selection or take to: −1 dBFS, a
/// little headroom for 44.1 kHz conversion and players that overshoot.
const normalizeTarget = 0.8912509381337456; // 10^(-1/20)

/// Where the sound is in timeline [peaks] (edit frames): from a little before
/// the first block reaching [threshold] to a little after the last one.
/// Null if nothing reaches it.
({int start, int end})? soundRange(
  Peaks peaks,
  int length,
  double threshold, {
  int pre = 480, // 10 ms: keep the attack whole
  int post = 2400, // 50 ms: let the tail ring out
}) {
  double level(int k) =>
      math.max(-peaks.minMax[2 * k], peaks.minMax[2 * k + 1]);
  int? first, last;
  for (var k = 0; k < peaks.blocks; k++) {
    if (level(k) >= threshold) {
      first ??= k;
      last = k;
    }
  }
  if (first == null) return null;
  final bf = peaks.blockFrames;
  return (
    start: math.max(0, first * bf - pre),
    end: math.min(length, (last! + 1) * bf + post),
  );
}

/// dBFS → linear.
double dbToGain(double db) => math.pow(10, db / 20).toDouble();
