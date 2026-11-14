// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// M4 render tests against the acceptance criteria in wiki/features/
// transpose.md and wiki/features/tempo.md: exact length, pitch kept under
// tempo changes (±5 cents), exact transposition, no timing drift, cancel.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pocket_audio/pocket_audio.dart';
import 'package:test/test.dart';

const sr = 48000;
late Directory dir;

String record(int frames, double Function(int) f, {String name = 'in'}) {
  final path = '${dir.path}/$name.wav';
  PocketAudio.beginRecording(path);
  const chunk = 48000;
  for (var i = 0; i < frames; i += chunk) {
    final n = math.min(chunk, frames - i);
    PocketAudio.processInput(
      Float32List.fromList([for (var k = 0; k < n; k++) f(i + k)]),
    );
  }
  PocketAudio.endRecording();
  return path;
}

Float32List readWav(String path) {
  final bytes = File(path).readAsBytesSync();
  // Our writer: 58-byte header, then float32 samples. Copy for alignment.
  return Float32List.view(Uint8List.fromList(bytes.sublist(58)).buffer);
}

Future<RenderState> render({
  required String input,
  required int start,
  required int end,
  required String output,
  double semitones = 0,
  double tempo = 1,
}) async {
  PocketAudio.startRender(
    input: input,
    start: start,
    end: end,
    output: output,
    semitones: semitones,
    tempo: tempo,
  );
  while (PocketAudio.renderState == RenderState.running) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return PocketAudio.renderState;
}

/// Frequency from upward zero crossings over [from, to) (linear
/// interpolation of each crossing).
double frequency(Float32List x, int from, int to) {
  double? first, last;
  var count = 0;
  for (var i = from + 1; i < to; i++) {
    if (x[i - 1] < 0 && x[i] >= 0) {
      final t = (i - 1) + (-x[i - 1]) / (x[i] - x[i - 1]);
      first ??= t;
      last = t;
      count++;
    }
  }
  return (count - 1) * sr / (last! - first!);
}

double cents(double f, double ref) => 1200 * math.log(f / ref) / math.ln2;

double sine440(int i) => 0.5 * math.sin(2 * math.pi * 440 * i / sr);

void main() {
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ps_dsp_');
    PocketAudio.inputGain = 1.0;
    PocketAudio.processInput(Float32List(sr));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('tempo', () {
    for (final tempo in [0.75, 1.25, 1.5]) {
      test(
        '${(tempo * 100).round()}%: exact length, pitch unchanged',
        () async {
          final input = record(sr * 6, sine440);
          final out = '${dir.path}/out.wav';
          expect(
            await render(
              input: input,
              start: 0,
              end: sr * 6,
              output: out,
              tempo: tempo,
            ),
            RenderState.done,
          );
          final y = readWav(out);
          expect(y.length, (sr * 6 / tempo).round(), reason: 'exact length');
          // Measure away from the edges.
          final f = frequency(y, y.length ~/ 4, y.length * 3 ~/ 4);
          expect(cents(f, 440).abs(), lessThan(5), reason: '$f Hz');
        },
      );
    }
  });

  group('transpose', () {
    for (final st in [12.0, -24.0, 7.0, 0.5]) {
      test('$st semitones: exact pitch, same length', () async {
        final input = record(sr * 4, sine440);
        final out = '${dir.path}/out.wav';
        await render(
          input: input,
          start: 0,
          end: sr * 4,
          output: out,
          semitones: st,
        );
        final y = readWav(out);
        expect(y.length, sr * 4);
        final want = 440 * math.pow(2, st / 12).toDouble();
        final f = frequency(y, y.length ~/ 4, y.length * 3 ~/ 4);
        expect(cents(f, want).abs(), lessThan(5), reason: '$f vs $want Hz');
      });
    }

    test('no timing drift: clicks stay in place when transposed', () async {
      // A click every 0.5 s on silence.
      double clicks(int i) => i % (sr ~/ 2) < 48 ? 0.8 : 0.0;
      final input = record(sr * 10, clicks);
      final out = '${dir.path}/out.wav';
      await render(
        input: input,
        start: 0,
        end: sr * 10,
        output: out,
        semitones: 12,
      );
      final y = readWav(out);
      // Energy centre of each half-second window should stay near its click.
      for (var k = 1; k < 19; k++) {
        final at = k * sr ~/ 2;
        var best = 0.0, bestI = at;
        for (var i = at - 4800; i < at + 4800; i++) {
          if (y[i].abs() > best) {
            best = y[i].abs();
            bestI = i;
          }
        }
        expect(
          (bestI - at).abs(),
          lessThan(sr ~/ 100),
          reason: 'click $k at $bestI, expected ~$at (≤ 10 ms)',
        );
      }
    });
  });

  test('renders a range of the recording', () async {
    final input = record(sr * 4, sine440);
    final out = '${dir.path}/out.wav';
    await render(
      input: input,
      start: sr,
      end: sr * 3,
      output: out,
      tempo: 1.25,
    );
    expect(readWav(out).length, (sr * 2 / 1.25).round());
  });

  test('cancel stops the render and leaves no file', () async {
    final input = record(sr * 60, sine440);
    final out = '${dir.path}/out.wav';
    PocketAudio.startRender(
      input: input,
      start: 0,
      end: sr * 60,
      output: out,
      semitones: 3,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    PocketAudio.cancelRender();
    while (PocketAudio.renderState == RenderState.running) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(PocketAudio.renderState, RenderState.cancelled);
    expect(File(out).existsSync(), isFalse);
    expect(File('$out.tmp').existsSync(), isFalse);
  });

  test('a new render replaces the running one', () async {
    final input = record(sr * 30, sine440);
    final a = PocketAudio.startRender(
      input: input,
      start: 0,
      end: sr * 30,
      output: '${dir.path}/a.wav',
      semitones: 1,
    );
    final b = PocketAudio.startRender(
      input: input,
      start: 0,
      end: sr,
      output: '${dir.path}/b.wav',
      semitones: 2,
    );
    expect(b, greaterThan(a));
    while (PocketAudio.renderState == RenderState.running) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(PocketAudio.renderState, RenderState.done);
    expect(File('${dir.path}/b.wav').existsSync(), isTrue);
    expect(File('${dir.path}/a.wav').existsSync(), isFalse);
  });

  test('speed: 1 minute renders quickly on this machine', () async {
    final input = record(sr * 60, sine440);
    final sw = Stopwatch()..start();
    await render(
      input: input,
      start: 0,
      end: sr * 60,
      output: '${dir.path}/out.wav',
      semitones: 5,
    );
    // ignore: avoid_print
    print('1-minute render on host: ${sw.elapsedMilliseconds} ms');
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the player plays clips from a render, and swaps back', () async {
    double ramp(int i) => (i % 1000) / 2000.0;
    final input = record(sr * 2, ramp);
    final out = '${dir.path}/r.wav';
    await render(input: input, start: 0, end: sr * 2, output: out, tempo: 1.25);
    final r = readWav(out);
    PocketAudio.openTake(input);
    final len = PocketAudio.setClips([
      PlayClip(1000, 21000, gain: 1.0),
    ], source: out);
    expect(len, 20000);
    PocketAudio.playing = true;
    final y = PocketAudio.renderPlayerOffline(4000);
    // After the 5 ms fade-in the output is the render, frame for frame.
    for (final k in [500, 1500, 3999]) {
      expect(y[2 * k], r[1000 + k], reason: 'frame $k');
    }
    // Back to the recording (null source).
    expect(PocketAudio.setClips(const []), sr * 2);
    expect(
      () => PocketAudio.setClips(const [], source: '${dir.path}/missing.wav'),
      throwsA(isA<PocketAudioException>()),
    );
    PocketAudio.closeTake();
  });
}
