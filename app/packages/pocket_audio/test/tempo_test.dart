// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// M5b tempo sync (wiki/decisions/d017-tempo-everywhere.md): the click,
// count-in before a take, synced loops (exact bars, musical-time playback)
// and feedback mode.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pocket_audio/pocket_audio.dart';
import 'package:test/test.dart';

const sr = 48000;
const block = 64;

Float32List readWav(String path) {
  final bytes = File(path).readAsBytesSync();
  return Float32List.view(Uint8List.fromList(bytes.sublist(58)).buffer);
}

double peakOf(Float32List x, int a, int b) {
  var m = 0.0;
  for (var i = math.max(0, a); i < math.min(b, x.length); i++) {
    m = math.max(m, x[i].abs());
  }
  return m;
}

void main() {
  group('click', () {
    test('a click on every beat, silent between, accent on the bar', () {
      const beat = 24000.0; // 120 BPM
      // Silent in the second half of a beat.
      for (final m in [2000.0, 12000.0, 23000.0, -5000.0]) {
        expect(Metronome.click(m, beat, 4), 0.0);
      }
      // Audible just after each beat (including the count-in's).
      for (final m in [100.0, 24100.0, -23900.0]) {
        expect(Metronome.click(m, beat, 4).abs(), greaterThan(0.01));
      }
      // Accent (beat 0 of a bar) is 1.5 kHz: a zero crossing every 16
      // frames; other beats 1 kHz: every 24.
      int crossings(double start) {
        var n = 0;
        for (var k = 50; k < 1000; k++) {
          final a = Metronome.click(start + k, beat, 4);
          final b = Metronome.click(start + k + 1, beat, 4);
          if (a.sign != b.sign && b != 0) n++;
        }
        return n;
      }

      expect(crossings(0), closeTo(950 / 16, 2));
      expect(crossings(beat), closeTo(950 / 24, 2));
      expect(crossings(-4 * beat), closeTo(950 / 16, 2), reason: 'count-in bar');
    });
  });

  group('recorder count-in', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ps_tempo_'));
    tearDown(() {
      Metronome.setGrid(0, 4);
      dir.deleteSync(recursive: true);
    });

    for (final clickAfter in [false, true]) {
      test('starts on the exact frame after the count-in '
          '(click after: $clickAfter)', () {
        const beat = 1000.0, countIn = 4000;
        Metronome.setGrid(beat, 4);
        final wav = '${dir.path}/t.wav';
        PocketAudio.beginRecordingCounted(
          wav,
          countInFrames: countIn,
          clickAfter: clickAfter,
        );
        // Input = its own frame number (from the count-in's first frame).
        final out = <double>[];
        for (var t = 0; t < 8000; t += block) {
          final input = Float32List(block);
          for (var k = 0; k < block; k++) {
            input[k] = (t + k) / 100000;
          }
          out.addAll(PocketAudio.processEngineOffline(input));
          if (t == 0) expect(Metronome.musical, -countIn + block);
        }
        PocketAudio.endRecording();
        final y = readWav(wav);
        expect(y.length, 8000 - countIn);
        expect(y.first, closeTo(countIn / 100000, 1e-7));
        // Clicks during the count-in; after it only with clickAfter.
        final o = Float32List.fromList(out);
        expect(peakOf(o, 0, 200), greaterThan(0.1));
        expect(peakOf(o, 3000, 3200), greaterThan(0.1));
        if (clickAfter) {
          expect(peakOf(o, 4000, 4200), greaterThan(0.1));
        } else {
          expect(peakOf(o, 4000, 8000), 0.0);
        }
        expect(Metronome.musical, isNull, reason: 'stops with the take');
      });
    }
  });

  group('looper sync', () {
    setUp(() {
      Looper.latencyFrames = 0;
      Looper.inputGain = 1;
      Looper.outputGain = 1;
      Looper.click = false;
      Looper.feedbackDb = 0;
      Looper.enable();
    });
    tearDown(() {
      Looper.setSync(0, 4, 0);
      Looper.disable();
    });

    /// Runs the looper on blocks; [input] gets the frame number since the
    /// press (the count-in's first frame).
    Float32List run(int from, int frames, double Function(int t) input) {
      final out = Float32List(frames);
      for (var i = 0; i < frames; i += block) {
        final x = Float32List(math.min(block, frames - i));
        for (var k = 0; k < x.length; k++) {
          x[k] = input(from + i + k);
        }
        out.setAll(i, Looper.processOffline(x));
      }
      return out;
    }

    for (final latency in [0, 300]) {
      for (final closeAt in [7600, 8400]) {
        test('exact bars, played downbeats line up (round trip $latency, '
            'closed at $closeAt)', () {
          const beat = 500.0, bar = 2000, countIn = 4; // 1 bar count-in
          Looper.latencyFrames = latency;
          Looper.setSync(beat, 4, countIn);
          // The performer hits on every beat they hear; it reaches the mic
          // one round trip later. Musical frame of t = t − 2000.
          double performer(int t) {
            final m = t - 2000 - latency;
            return m >= 0 && m % 500 == 0 ? 1.0 : 0.0;
          }

          Looper.press();
          var t = 0;
          final first = run(t, block, performer);
          t += block;
          expect(Looper.state, LooperState.countIn);
          expect(peakOf(first, 0, block), greaterThan(0.01), reason: 'click');
          run(t, 2000 + closeAt - t, performer);
          t = 2000 + closeAt;
          Looper.press(); // close near bar 4
          var guard = 0;
          while (Looper.state != LooperState.playing) {
            run(t, block, performer);
            t += block;
            if (++guard > 1000) fail('never closed');
          }
          expect(Looper.length, 4 * bar, reason: 'nearest whole bars');
          // From now on the loop alone (performer stops): its hits are on
          // the musical beats.
          final out = run(t, 3 * Looper.length, (_) => 0.0);
          for (var i = 0; i < out.length; i++) {
            if (out[i].abs() > 0.5) {
              final m = t + i - 2000;
              expect(m % 500, 0, reason: 'hit at musical frame $m');
            }
          }
          // Every beat is there (the seam keeps the downbeat).
          var hits = 0;
          for (final v in out) {
            if (v.abs() > 0.5) hits++;
          }
          expect(hits, 3 * 16);
        });
      }
    }

    test('feedback: −6 dB per pass, smoothly', () {
      Looper.feedbackDb = 6;
      Looper.press();
      run(0, 9600, (_) => 0.5);
      Looper.press();
      var t = 9600;
      while (Looper.state != LooperState.playing) {
        run(t, block, (_) => 0.5);
        t += block;
      }
      final len = Looper.length;
      final out = run(t, 2 * len, (_) => 0.0);
      final a = out[1000], b = out[1000 + len];
      expect(b / a, closeTo(0.5012, 0.01)); // −6 dB
      // No step anywhere (a smooth fade, not a jump per pass).
      for (var i = 600; i < out.length; i++) {
        expect((out[i] - out[i - 1]).abs(), lessThan(1e-3));
      }
    });
  });
}
