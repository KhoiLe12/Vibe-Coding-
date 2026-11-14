// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Layers (M6) engine tests against wiki/features/layers.md: offsets are
// sample-exact, no clicks at layer edges, smoothed volumes, bounce = playback,
// a layer recorded over the stack lines up within 1 ms, 8 layers keep up.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pocket_audio/pocket_audio.dart';
import 'package:test/test.dart';

const sr = 48000;
const block = 256;
late Directory dir;

String take(String name, int frames, double Function(int) f) {
  final path = '${dir.path}/$name.wav';
  PocketAudio.beginRecording(path);
  for (var i = 0; i < frames; i += sr) {
    final n = math.min(sr, frames - i);
    PocketAudio.processInput(
      Float32List.fromList([for (var k = 0; k < n; k++) f(i + k)]),
    );
  }
  PocketAudio.endRecording();
  return path;
}

StackTrack whole(String path, int frames, int offset) =>
    StackTrack(path, offset, [(start: 0, end: frames, gain: 1.0)]);

Float32List play(int frames) {
  final out = Float32List(frames);
  for (var i = 0; i < frames; i += block) {
    final n = math.min(block, frames - i);
    final st = PocketAudio.renderPlayerOffline(n);
    for (var k = 0; k < n; k++) {
      out[i + k] = st[2 * k];
    }
  }
  return out;
}

double maxJump(Float32List x) {
  var m = 0.0;
  for (var i = 1; i < x.length; i++) {
    m = math.max(m, (x[i] - x[i - 1]).abs());
  }
  return m;
}

final _f = Float32List(1);
double f32(double x) => (_f..[0] = x)[0];

void main() {
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ps_layers_');
    PocketAudio.inputGain = 1.0;
    PocketAudio.processInput(Float32List(sr));
    PocketAudio.openStack();
  });
  tearDown(() {
    PocketAudio.closeTake();
    dir.deleteSync(recursive: true);
  });

  test('layers mix at their offsets, sample-exact away from the edges', () {
    double a(int i) => i / 1e6;
    double b(int i) => 0.25 + i / 1e7;
    final pa = take('a', sr, a), pb = take('b', sr ~/ 2, b);
    final len = PocketAudio.setStack([
      whole(pa, sr, 0),
      whole(pb, sr ~/ 2, 1000),
    ]);
    expect(len, sr, reason: 'the end of the last layer');
    PocketAudio.playing = true;
    final y = play(sr);
    for (final t in [500, 2000, 10000, 24000]) {
      final want = f32(a(t)) + (t >= 1000 + 240 ? f32(b(t - 1000)) : 0);
      if (t < 1000 + 240 && t >= 1000) continue; // inside B's fade-in
      expect(y[t], closeTo(want, 1e-6), reason: 'frame $t');
    }
  });

  test('no clicks where a layer starts or ends', () {
    final p = take('c', sr ~/ 2, (_) => 0.5);
    PocketAudio.setStack([whole(p, sr ~/ 2, 4800)]);
    PocketAudio.playing = true;
    final y = play(sr);
    expect(y[4000], 0);
    expect(y[4800 + 1000], closeTo(0.5, 1e-6));
    // A 0.5 step spread over 5 ms (plus the start fade of play itself).
    expect(maxJump(y), lessThanOrEqualTo(0.5 / 240 + 1e-6));
  });

  test('layer volume changes are smoothed', () {
    final p = take('d', sr, (_) => 0.5);
    PocketAudio.setStack([whole(p, sr, 0)]);
    PocketAudio.playing = true;
    play(2400);
    PocketAudio.setTrackGain(0, 0);
    final y = play(2400);
    expect(maxJump(y), lessThanOrEqualTo(0.5 / 240 + 1e-6));
    expect(y.last, 0);
    PocketAudio.setTrackGain(0, 1);
  });

  test('a bounce is exactly what plays', () {
    final pa = take('e', sr, (i) => 0.3 * math.sin(i / 7));
    final pb = take('f', sr, (i) => 0.2 * math.sin(i / 3));
    PocketAudio.setStack([whole(pa, sr, 0), whole(pb, sr, 7777)]);
    PocketAudio.setTrackGain(1, 0.5);
    PocketAudio.playing = true;
    final y = play(sr + 7777);
    final path = '${dir.path}/bounce.wav';
    PocketAudio.bounceMix(path);
    final b = Float32List.view(
      Uint8List.fromList(File(path).readAsBytesSync().sublist(58)).buffer,
    );
    expect(b.length, sr + 7777);
    // After play's own 5 ms fade-in, playback and bounce are identical.
    for (var t = 500; t < b.length; t += 101) {
      expect(y[t], closeTo(b[t], 1e-6), reason: 'frame $t');
    }
    PocketAudio.setTrackGain(1, 1);
  });

  test('a layer recorded over the stack lines up within 1 ms', () {
    // At least one block: the room can only return what was already played.
    for (final delay in [block, 1440, 3000]) {
      PocketAudio.openStack();
      // The stack: one click at 0.5 s.
      const clickAt = sr ~/ 2;
      final p = take('click', sr * 2, (i) => i == clickAt ? 1.0 : 0.0);
      PocketAudio.setStack([whole(p, sr * 2, 0)]);
      PocketAudio.seek(sr ~/ 10); // start partway in, like a user would
      PocketAudio.playing = true;
      // Record while playing, through the full callback. The room returns
      // the speaker output to the mic `delay` frames later (bleed), so the
      // click arrives one round trip after it was played.
      final rec = '${dir.path}/layer$delay.wav';
      PocketAudio.beginRecording(rec);
      final history = <double>[];
      for (var t = 0; t < sr * 2; t += block) {
        final input = Float32List(block);
        for (var k = 0; k < block; k++) {
          final src = t + k - delay;
          input[k] = src >= 0 && src < history.length ? history[src] : 0;
        }
        history.addAll(PocketAudio.processEngineOffline(input));
      }
      PocketAudio.endRecording();
      final stamp = PocketAudio.recorderStartStamp;
      expect(stamp, greaterThanOrEqualTo(sr ~/ 10));
      final offset = stamp - delay; // calibrated round trip
      final r = Float32List.view(
        Uint8List.fromList(File(rec).readAsBytesSync().sublist(58)).buffer,
      );
      var best = 0;
      for (var i = 0; i < r.length; i++) {
        if (r[i].abs() > r[best].abs()) best = i;
      }
      expect(r[best].abs(), greaterThan(0.5), reason: 'click recorded');
      expect(
        (offset + best - clickAt).abs(),
        lessThanOrEqualTo(sr ~/ 1000),
        reason: 'delay $delay: lands at ${offset + best}, click at $clickAt',
      );
    }
  });

  test('8 layers play faster than real time (host CPU check)', () {
    final tracks = <StackTrack>[];
    for (var k = 0; k < 8; k++) {
      final p = take('l$k', sr * 5, (i) => 0.1 * math.sin(i / (3 + k)));
      tracks.add(whole(p, sr * 5, k * 1000));
    }
    PocketAudio.setStack(tracks);
    PocketAudio.playing = true;
    final sw = Stopwatch()..start();
    play(sr * 5);
    // ignore: avoid_print
    print('8 layers: 5 s of audio in ${sw.elapsedMilliseconds} ms on the host');
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });
}
