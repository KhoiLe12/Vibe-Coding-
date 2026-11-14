// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Tempo detection (M5b, wiki/features/beat-grid.md) on synthetic drum
// patterns with known tempo and downbeat.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pocket_audio/pocket_audio.dart';
import 'package:test/test.dart';

const sr = 48000;

/// A bar of 4/4: accented kick on 1, kick on 3, snare on 2 and 4, closed
/// hats on eighths, a soft sustained chord; starting [lead] frames in.
Float32List drums(double bpm, int seconds, {int lead = 0, int seed = 1}) {
  final n = seconds * sr;
  final y = Float32List(n);
  final rnd = math.Random(seed);
  final beat = sr * 60 / bpm;
  void hit(double at, double Function(int k) f, int len) {
    final a = at.round();
    for (var k = 0; k < len && a + k < n; k++) {
      if (a + k >= 0) y[a + k] += f(k);
    }
  }

  double noise() => rnd.nextDouble() * 2 - 1;
  for (var b = 0; lead + b * beat < n; b++) {
    final t = lead + b * beat;
    final inBar = b % 4;
    if (inBar == 0 || inBar == 2) {
      // Kick (accented on the bar's first beat): a falling 55 Hz sine.
      final g = inBar == 0 ? 0.9 : 0.6;
      hit(
        t,
        (k) =>
            g *
            math.exp(-k / 4000) *
            math.sin(2 * math.pi * 55 * k / sr * (1 + 2 * math.exp(-k / 800))),
        12000,
      );
    } else {
      // Snare: noise and a 185 Hz body.
      hit(
        t,
        (k) =>
            math.exp(-k / 2500) *
            (0.35 * noise() + 0.3 * math.sin(2 * math.pi * 185 * k / sr)),
        8000,
      );
    }
    // Closed hats on eighths: high-passed noise (real hats sit above 5 kHz).
    for (final h in [0.0, 0.5]) {
      var p1 = 0.0, p2 = 0.0;
      hit(t + h * beat, (k) {
        final x = noise();
        final d = x - p1, d2 = d - p2;
        p1 = x;
        p2 = d;
        return 0.08 * math.exp(-k / 600) * d2;
      }, 2000);
    }
  }
  // A soft sustained chord.
  for (var i = 0; i < n; i++) {
    y[i] +=
        0.05 *
        (math.sin(2 * math.pi * 220 * i / sr) +
            math.sin(2 * math.pi * 277 * i / sr));
  }
  return y;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ps_tdet_'));
  tearDown(() => dir.deleteSync(recursive: true));

  String wav(Float32List x) {
    final path = '${dir.path}/${x.hashCode}.wav';
    PocketAudio.beginRecording(path);
    PocketAudio.processInput(x);
    PocketAudio.endRecording();
    return path;
  }

  for (final bpm in [75.0, 85.0, 100.0, 120.0, 128.0, 140.0, 160.0, 96.5]) {
    for (final lead in [0, 7919]) {
      test('$bpm BPM, first beat at $lead', () {
        final x = drums(bpm, 20, lead: lead);
        final r = PocketAudio.detectTempo(
          source: wav(x),
          clips: [PlayClip(0, x.length)],
        )!;
        expect(r.bpm, closeTo(bpm, 0.3));
        final beat = sr * 60 / bpm;
        // On a downbeat (bar = 4 beats; beat 3's kick is weaker), within
        // 12 ms.
        final bar = 4 * beat;
        final off = ((r.firstBeat - lead) % bar + bar) % bar;
        final err = math.min(off, bar - off);
        expect(err, lessThan(0.012 * sr), reason: 'first beat ${r.firstBeat}');
        expect(r.confidence, greaterThan(0.2));
      });
    }
  }

  test('follows the clips (a chopped take is analysed as it plays)', () {
    final x = drums(120, 20, lead: 3000);
    // Skip the first 10 000 frames: beats now at 3000 + 24000k − 10000.
    final r = PocketAudio.detectTempo(
      source: wav(x),
      clips: [PlayClip(10000, x.length)],
    )!;
    expect(r.bpm, closeTo(120, 0.3));
    final off = ((r.firstBeat - (3000 - 10000)) % 96000 + 96000) % 96000;
    expect(math.min(off, 96000 - off), lessThan(600));
  });

  test('silence and noise: no tempo, or no confidence', () {
    final silent = Float32List(sr * 5);
    expect(
      PocketAudio.detectTempo(
        source: wav(silent),
        clips: [PlayClip(0, silent.length)],
      ),
      isNull,
    );
  });
}
