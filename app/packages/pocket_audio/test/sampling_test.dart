// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// M7 sampling tools in the engine (wiki/features/sampling-tools.md):
// reverse and fade envelopes in playback, varispeed renders, export to
// 16/24/32-bit WAV at 48/44.1 kHz with seamless loops, peak scan.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pocket_audio/pocket_audio.dart';
import 'package:test/test.dart';

const sr = 48000;
late Directory dir;

String record(int frames, double Function(int) f, {String name = 't'}) {
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

Float32List renderAll(int frames) {
  final out = Float32List(frames);
  for (var i = 0; i < frames; i += 256) {
    final n = math.min(256, frames - i);
    final st = PocketAudio.renderPlayerOffline(n);
    for (var k = 0; k < n; k++) {
      out[i + k] = st[2 * k];
    }
  }
  return out;
}

double maxJump(Float32List x, [int from = 1, int? to]) {
  var m = 0.0;
  for (var i = math.max(1, from); i < (to ?? x.length); i++) {
    m = math.max(m, (x[i] - x[i - 1]).abs());
  }
  return m;
}

final _f = Float32List(1);
double f32(double x) => (_f..[0] = x)[0];

/// Our recorder's float WAV: 58-byte header.
Float32List readFloatTake(String path) {
  final bytes = File(path).readAsBytesSync();
  return Float32List.view(Uint8List.fromList(bytes.sublist(58)).buffer);
}

/// A parsed export: format fields, samples as floats, and any smpl loop.
class Wav {
  Wav(String path) {
    final b = ByteData.sublistView(File(path).readAsBytesSync());
    String tag(int at) =>
        String.fromCharCodes(Uint8List.sublistView(b, at, at + 4));
    expect(tag(0), 'RIFF');
    expect(b.getUint32(4, Endian.little), b.lengthInBytes - 8);
    expect(tag(8), 'WAVE');
    var pos = 12;
    while (pos + 8 <= b.lengthInBytes) {
      final id = tag(pos);
      final size = b.getUint32(pos + 4, Endian.little);
      final body = pos + 8;
      if (id == 'fmt ') {
        format = b.getUint16(body, Endian.little);
        channels = b.getUint16(body + 2, Endian.little);
        rate = b.getUint32(body + 4, Endian.little);
        bits = b.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        final n = size ~/ (bits ~/ 8);
        samples = Float32List(n);
        for (var i = 0; i < n; i++) {
          samples[i] = switch (bits) {
            16 => b.getInt16(body + 2 * i, Endian.little) / 32768,
            24 =>
              ((b.getUint8(body + 3 * i) |
                      b.getUint8(body + 3 * i + 1) << 8 |
                      b.getInt8(body + 3 * i + 2) << 16)) /
                  8388608,
            _ => b.getFloat32(body + 4 * i, Endian.little),
          };
        }
      } else if (id == 'smpl') {
        expect(b.getUint32(body + 28, Endian.little), 1); // one loop
        loopStart = b.getUint32(body + 36 + 8, Endian.little);
        loopEnd = b.getUint32(body + 36 + 12, Endian.little);
      }
      pos = body + size + (size & 1);
    }
  }

  late int format, channels, rate, bits;
  late Float32List samples;
  int? loopStart, loopEnd;
}

double sine(int i, [double hz = 440]) =>
    0.5 * math.sin(2 * math.pi * hz * i / sr);

/// Frequency from upward zero crossings over [from, to).
double frequency(Float32List x, int from, int to, {int rate = sr}) {
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
  return (count - 1) * rate / (last! - first!);
}

double cents(double f, double ref) => 1200 * math.log(f / ref) / math.ln2;

Future<RenderState> renderJob({
  required String input,
  required int start,
  required int end,
  required String output,
  double semitones = 0,
  double tempo = 1,
  double speed = 1,
}) async {
  PocketAudio.startRender(
    input: input,
    start: start,
    end: end,
    output: output,
    semitones: semitones,
    tempo: tempo,
    speed: speed,
  );
  while (PocketAudio.renderState == RenderState.running) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return PocketAudio.renderState;
}

void main() {
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ps_sampling_');
    PocketAudio.inputGain = 1.0;
    PocketAudio.processInput(Float32List(sr));
  });
  tearDown(() {
    PocketAudio.closeTake();
    dir.deleteSync(recursive: true);
  });

  group('playback', () {
    test('a reversed clip plays its frames backwards, sample-exact', () {
      double ramp(int i) => i / 1e6;
      PocketAudio.openTake(record(sr, ramp));
      final len = PocketAudio.setClips([
        const PlayClip(10000, 30000, reverse: true),
      ]);
      expect(len, 20000);
      PocketAudio.seek(0);
      PocketAudio.playing = true;
      final out = renderAll(20000);
      for (final t in [1000, 5000, 19999]) {
        expect(out[t], f32(ramp(29999 - t)), reason: 'frame $t');
      }
    });

    test('reverse a selection: reversed pieces in reverse order = exact '
        'mirror, and a split inside it needs no crossfade', () {
      double ramp(int i) => i / 1e6;
      PocketAudio.openTake(record(sr, ramp));
      // [0,10000) forwards, then [10000,20000) reversed as two pieces:
      // [15000,20000) reversed first, then [10000,15000) reversed.
      PocketAudio.setClips([
        const PlayClip(0, 10000),
        const PlayClip(15000, 20000, reverse: true),
        const PlayClip(10000, 15000, reverse: true),
      ]);
      PocketAudio.seek(0);
      PocketAudio.playing = true;
      final out = renderAll(20000);
      // Around the reversed pieces' join (15000 on the timeline): exact.
      for (var t = 14900; t < 15100; t++) {
        expect(out[t], f32(ramp(19999 - (t - 10000))), reason: 'frame $t');
      }
    });

    test('a fade in rises smoothly from silence; a fade out ends silent', () {
      PocketAudio.openTake(record(sr, (_) => 0.5));
      PocketAudio.setClips([
        const PlayClip(0, 4800, fades: Fades(inB: 4800)),
        const PlayClip(4800, 9600),
        const PlayClip(9600, 14400, fades: Fades(outB: 4800)),
      ]);
      PocketAudio.seek(0);
      PocketAudio.playing = true;
      final out = renderAll(14400);
      expect(out[0].abs(), lessThan(1e-4));
      expect(out[2400], closeTo(0.25, 0.01)); // sin² halfway = 0.5
      expect(out[7200], closeTo(0.5, 1e-6));
      expect(out[14399].abs(), lessThan(1e-4));
      // No step anywhere: at most the fade's own slope (~0.5 * π/2 / 4800).
      expect(maxJump(out), lessThan(2e-4));
    });

    test('a fade can end inside a clip, and a split inside a fade plays '
        'exactly as before (no join crossfade)', () {
      PocketAudio.openTake(record(sr, (_) => 0.5));
      // One clip, fade in over its first 2400 frames, fade out over its last
      // 2400.
      PocketAudio.setClips([
        const PlayClip(
          0,
          9600,
          fades: Fades(inB: 2400, outA: 7200, outB: 9600),
        ),
      ]);
      PocketAudio.seek(0);
      PocketAudio.playing = true;
      final whole = renderAll(9600);
      expect(whole[1200], closeTo(0.25, 0.01));
      expect(whole[4800], closeTo(0.5, 1e-6));
      expect(whole[9599].abs(), lessThan(1e-4));
      // Split at 1000 (inside the fade in) and 8000 (inside the fade out).
      const f = Fades(inB: 2400, outA: 7200, outB: 9600);
      PocketAudio.setClips([
        const PlayClip(0, 1000, fades: f),
        PlayClip(1000, 8000, fades: f.shift(1000)),
        PlayClip(8000, 9600, fades: f.shift(8000)),
      ]);
      PocketAudio.seek(0);
      PocketAudio.playing = true;
      final split = renderAll(9600);
      for (var t = 300; t < 9600; t++) {
        expect(split[t], closeTo(whole[t], 1e-6), reason: 'frame $t');
      }
    });

    test('fades shape a stack layer too', () {
      final path = record(sr, (_) => 0.5);
      PocketAudio.openStack();
      PocketAudio.setStack([
        StackTrack(path, 0, const [PlayClip(0, 4800, fades: Fades(inB: 4800))]),
      ]);
      PocketAudio.seek(0);
      PocketAudio.playing = true;
      final out = renderAll(4800);
      expect(out[2400], closeTo(0.25, 0.01));
    });
  });

  group('varispeed', () {
    for (final speed in [2.0, 0.5, 1.5]) {
      test('×$speed: pitch moves with speed, exact length', () async {
        final input = record(sr * 4, sine);
        final out = '${dir.path}/v.wav';
        expect(
          await renderJob(
            input: input,
            start: 0,
            end: sr * 4,
            output: out,
            speed: speed,
          ),
          RenderState.done,
        );
        final x = readFloatTake(out);
        expect(x.length, (sr * 4 / speed).round());
        final f = frequency(x, 2000, x.length - 2000);
        expect(cents(f, 440 * speed).abs(), lessThan(1));
      });
    }

    test('×4 (+24 st) of a high tone does not alias back down', () async {
      // 9 kHz × 4 = 36 kHz, above Nyquist: must vanish, not fold to 12 kHz.
      final input = record(sr, (i) => sine(i, 9000));
      final out = '${dir.path}/v.wav';
      await renderJob(input: input, start: 0, end: sr, output: out, speed: 4);
      final x = readFloatTake(out);
      var peak = 0.0;
      for (var i = 500; i < x.length - 500; i++) {
        peak = math.max(peak, x[i].abs());
      }
      expect(peak, lessThan(0.005)); // < -40 dB re 0.5
    });

    test('with pitch and tempo: both apply, then varispeed', () async {
      final input = record(sr * 4, sine);
      final out = '${dir.path}/v.wav';
      expect(
        await renderJob(
          input: input,
          start: 0,
          end: sr * 4,
          output: out,
          semitones: 12,
          tempo: 1.25,
          speed: 0.5,
        ),
        RenderState.done,
      );
      final x = readFloatTake(out);
      expect(x.length, ((sr * 4 / 1.25).round() / 0.5).round());
      // +12 st, then an octave down: back at 440.
      final f = frequency(x, sr, x.length - sr);
      expect(cents(f, 440).abs(), lessThan(5));
      expect(File('$out.stretched').existsSync(), isFalse);
    });

    test('"keep voice natural" keeps formants under varispeed', () async {
      // A vowel-like tone: 150 Hz harmonics shaped by one resonance at
      // 1.2 kHz. Varispeed ×2 alone moves the resonance to 2.4 kHz; with
      // formants kept it stays near 1.2 kHz while the pitch doubles.
      double vowel(int i) {
        var y = 0.0;
        for (var h = 1; h * 150 < 6000; h++) {
          final f = h * 150.0;
          final a = math.exp(-math.pow((f - 1200) / 250, 2));
          y += 0.08 * a * math.sin(2 * math.pi * f * i / sr);
        }
        return y;
      }

      final input = record(sr * 3, vowel);
      Future<(double, double)> peakHarmonic({required bool formant}) async {
        final out = '${dir.path}/v${formant ? 'f' : ''}.wav';
        PocketAudio.startRender(
          input: input,
          start: 0,
          end: sr * 3,
          output: out,
          formant: formant,
          speed: 2,
        );
        while (PocketAudio.renderState == RenderState.running) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(PocketAudio.renderState, RenderState.done);
        final x = readFloatTake(out);
        expect(x.length, (sr * 3 / 2).round());
        // Goertzel at each harmonic of 300 Hz over the middle second.
        var best = 0.0, bestF = 0.0;
        const from = sr ~/ 4, n = sr;
        for (var h = 1; h * 300 < 6000; h++) {
          final f = h * 300.0;
          var re = 0.0, im = 0.0;
          for (var i = 0; i < n; i++) {
            final w = 2 * math.pi * f * i / sr;
            re += x[from + i] * math.cos(w);
            im += x[from + i] * math.sin(w);
          }
          final mag = math.sqrt(re * re + im * im);
          if (mag > best) {
            best = mag;
            bestF = f;
          }
        }
        // Fundamental by autocorrelation (lags for 200–600 Hz: one period).
        var bestLag = 0, bestR = -1e9;
        for (var lag = sr ~/ 600; lag <= sr ~/ 200; lag++) {
          var r = 0.0;
          for (var i = 0; i < 12000; i++) {
            r += x[from + i] * x[from + i + lag];
          }
          if (r > bestR) {
            bestR = r;
            bestLag = lag;
          }
        }
        return (bestF, sr / bestLag);
      }

      final (plainPeak, plainF0) = await peakHarmonic(formant: false);
      final (keptPeak, keptF0) = await peakHarmonic(formant: true);
      expect(plainF0, closeTo(300, 3));
      expect(keptF0, closeTo(300, 3));
      expect(plainPeak, inInclusiveRange(2100, 2700));
      expect(keptPeak, inInclusiveRange(900, 1500));
    });

    test('1 minute of varispeed renders in well under a second', () async {
      final input = record(sr * 60, sine);
      final sw = Stopwatch()..start();
      await renderJob(
        input: input,
        start: 0,
        end: sr * 60,
        output: '${dir.path}/v.wav',
        speed: 1.5,
      );
      sw.stop();
      // ignore: avoid_print
      print('varispeed: 60 s at ×1.5 in ${sw.elapsedMilliseconds} ms');
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });
  });

  group('export', () {
    test('24-bit 48 kHz: matches the clips sample for sample', () {
      double ramp(int i) => (i % 1000) / 1000 - 0.5;
      final src = record(sr, ramp);
      final out = '${dir.path}/e.wav';
      PocketAudio.exportWav(
        source: src,
        clips: const [PlayClip(2000, 6000, gain: 0.5, reverse: true)],
        output: out,
      );
      final w = Wav(out);
      expect((w.format, w.channels, w.rate, w.bits), (1, 1, 48000, 24));
      expect(w.samples.length, 4000);
      expect(w.loopEnd, isNull);
      for (var i = 0; i < 4000; i++) {
        expect(w.samples[i], closeTo(0.5 * ramp(5999 - i), 1.5 / 8388608));
      }
    });

    test('16-bit is dithered PCM; 32-bit is float; empty clips = all', () {
      final src = record(sr ~/ 2, sine);
      final a = '${dir.path}/a.wav', b = '${dir.path}/b.wav';
      PocketAudio.exportWav(
        source: src,
        clips: const [],
        output: a,
        bits: ExportBits.pcm16,
      );
      PocketAudio.exportWav(
        source: src,
        clips: const [],
        output: b,
        bits: ExportBits.float32,
      );
      final w16 = Wav(a), w32 = Wav(b);
      expect((w16.format, w16.bits), (1, 16));
      expect((w32.format, w32.bits), (3, 32));
      expect(w16.samples.length, sr ~/ 2);
      final x = readFloatTake(src);
      for (var i = 0; i < x.length; i++) {
        expect(w32.samples[i], x[i]);
        expect(w16.samples[i], closeTo(x[i], 2 / 32768));
      }
    });

    test('44.1 kHz: resampled, same pitch, right length', () {
      final src = record(sr * 2, sine);
      final out = '${dir.path}/e.wav';
      PocketAudio.exportWav(
        source: src,
        clips: const [],
        output: out,
        sampleRate: 44100,
      );
      final w = Wav(out);
      expect(w.rate, 44100);
      expect(w.samples.length, (sr * 2 * 44100 / 48000).round());
      final f = frequency(
        w.samples,
        2000,
        w.samples.length - 2000,
        rate: 44100,
      );
      expect(cents(f, 440).abs(), lessThan(0.5));
      var peak = 0.0;
      for (var i = 2000; i < w.samples.length - 2000; i++) {
        peak = math.max(peak, w.samples[i].abs());
      }
      expect(peak, closeTo(0.5, 0.01));
    });

    test('loop with audio after it: the wrap is seamless, length exact, '
        'smpl loop covers the file', () {
      // 441 Hz does not fit a 1 s loop evenly (441 cycles do, so use 0.99 s):
      // a plain cut would jump at the wrap.
      final src = record(sr * 2, (i) => sine(i, 441));
      const loop = 47520; // 0.99 s
      final out = '${dir.path}/e.wav';
      PocketAudio.exportWav(
        source: src,
        clips: const [PlayClip(1000, 1000 + loop + 480)],
        output: out,
        loopFrames: loop,
      );
      final w = Wav(out);
      expect(w.samples.length, loop);
      expect((w.loopStart, w.loopEnd), (0, loop - 1));
      // Wrapped around, the file never jumps more than the sine's own slope.
      final wrapped = Float32List.fromList([
        ...w.samples.sublist(loop - 2000),
        ...w.samples.sublist(0, 2000),
      ]);
      const slope = 0.5 * 2 * math.pi * 441 / sr;
      expect(maxJump(wrapped), lessThan(slope * 1.05));
      // Away from the head, untouched.
      final x = readFloatTake(src);
      expect(w.samples[10000], closeTo(x[11000], 1.5 / 8388608));
    });

    test('loop with nothing after it: short fades at both ends', () {
      final src = record(sr, (_) => 0.5);
      final out = '${dir.path}/e.wav';
      PocketAudio.exportWav(
        source: src,
        clips: const [PlayClip(0, 24000)],
        output: out,
        loopFrames: 24000,
      );
      final w = Wav(out);
      expect(w.samples.length, 24000);
      expect(w.samples.first.abs(), lessThan(0.01));
      expect(w.samples.last.abs(), lessThan(0.01));
      expect(w.samples[12000], closeTo(0.5, 1e-6));
    });

    test('a loop at 44.1 kHz wraps seamlessly too', () {
      final src = record(sr * 2, (i) => sine(i, 441));
      const loop = 47520;
      final out = '${dir.path}/e.wav';
      PocketAudio.exportWav(
        source: src,
        clips: const [PlayClip(0, loop + 480)],
        output: out,
        sampleRate: 44100,
        loopFrames: loop,
      );
      final w = Wav(out);
      final n = (loop * 44100 / 48000).round();
      expect(w.samples.length, n);
      expect(w.loopEnd, n - 1);
      final wrapped = Float32List.fromList([
        ...w.samples.sublist(n - 500),
        ...w.samples.sublist(0, 500),
      ]);
      const slope = 0.5 * 2 * math.pi * 441 / 44100;
      expect(maxJump(wrapped), lessThan(slope * 1.1));
    });

    test('a missing source fails cleanly and leaves no file', () {
      final out = '${dir.path}/e.wav';
      expect(
        () => PocketAudio.exportWav(
          source: '${dir.path}/missing.wav',
          clips: const [],
          output: out,
        ),
        throwsA(isA<PocketAudioException>()),
      );
      expect(File(out).existsSync(), isFalse);
      expect(File('$out.tmp').existsSync(), isFalse);
    });
  });

  test('peak finds the largest sample in the given ranges only', () {
    final src = record(sr, (i) => i == 30000 ? -0.9 : (i == 100 ? 0.4 : 0.1));
    expect(PocketAudio.peak(src, [(start: 0, end: 1000)]), closeTo(0.4, 1e-6));
    expect(
      PocketAudio.peak(src, [
        (start: 0, end: 1000),
        (start: 29000, end: 31000),
      ]),
      closeTo(0.9, 1e-6),
    );
    expect(
      PocketAudio.peak(src, [(start: 200, end: 1000)]),
      closeTo(0.1, 1e-6),
    );
  });
}
