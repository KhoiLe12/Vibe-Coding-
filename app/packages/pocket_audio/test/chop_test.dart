// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// M3 engine side: the player plays an edit list as one timeline with 10 ms
// equal-power joins (wiki/decisions/d012-chop-model.md). Acceptance: no
// audible click at any cut (wiki/features/chop.md).

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pocket_audio/pocket_audio.dart';
import 'package:test/test.dart';

const sr = 48000;
late Directory dir;

/// Records [frames] of [f] (frame → sample) as a take and opens it.
void openTake(int frames, double Function(int) f) {
  final path = '${dir.path}/t.wav';
  PocketAudio.beginRecording(path);
  PocketAudio.processInput(
    Float32List.fromList([for (var i = 0; i < frames; i++) f(i)]),
  );
  PocketAudio.endRecording();
  PocketAudio.openTake(path);
}

double sine(int i) => 0.5 * math.sin(2 * math.pi * 440 * i / sr);
const sineStep = 0.5 * 2 * math.pi * 440 / sr;

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
    dir = Directory.systemTemp.createTempSync('ps_chop_');
    PocketAudio.inputGain = 1.0;
    PocketAudio.processInput(Float32List(sr));
  });
  tearDown(() {
    PocketAudio.closeTake();
    dir.deleteSync(recursive: true);
  });

  test('clips play in list order, away from joins sample-exact', () {
    // Ramp signal: sample value encodes its own frame number.
    double ramp(int i) => i / 1e6;
    openTake(sr, ramp);
    final len = PocketAudio.setClips([
      PlayClip(30000, 40000, gain: 1.0),
      PlayClip(0, 10000, gain: 1.0),
    ]);
    expect(len, 20000);
    expect(PocketAudio.takeLength, 20000);
    PocketAudio.seek(0);
    PocketAudio.playing = true;
    final out = renderAll(20000);
    // Past the 5 ms fade-in, before the join zone (10000 - 240).
    for (final t in [1000, 5000, 9000]) {
      expect(out[t], f32(ramp(30000 + t)), reason: 'frame $t');
    }
    for (final t in [10300, 15000, 19000]) {
      expect(out[t], f32(ramp(t - 10000)), reason: 'frame $t');
    }
  });

  test(
    'no click at cuts placed at the worst sine phase, with gain changes',
    () {
      openTake(sr * 3, sine);
      // Cut points at peaks (worst case: full-scale jump without a crossfade).
      final peak = sr ~/ 440 ~/ 4; // quarter period → sine peak
      PocketAudio.setClips([
        PlayClip(0, 10000 + peak, gain: 1.0),
        PlayClip(40000 + 3 * peak, 70000, gain: 0.8), // jumps peak → trough
        PlayClip(5000, 20000 + peak, gain: 1.0),
        PlayClip(100000, 110000, gain: 0.5),
      ]);
      PocketAudio.seek(0);
      PocketAudio.playing = true;
      final out = renderAll(PocketAudio.takeLength);
      expect(maxJump(out.sublist(300)), lessThan(sineStep * 1.5));
    },
  );

  test('without the crossfade that same edit would click (test sanity)', () {
    final a = [for (var i = 0; i < 2000; i++) sine(10000 + 27 + i - 2000)];
    final b = [for (var i = 0; i < 2000; i++) sine(40000 + 81 + i)];
    final hard = Float32List.fromList([...a, ...b]);
    expect(maxJump(hard), greaterThan(sineStep * 10));
  });

  test('adjacent pieces of the recording join without any crossfade', () {
    double ramp(int i) => i / 1e6;
    openTake(sr, ramp);
    PocketAudio.setClips([
      PlayClip(0, 20000, gain: 1.0),
      PlayClip(20000, 30000, gain: 1.0), // a split, nothing removed
    ]);
    PocketAudio.playing = true;
    final out = renderAll(30000);
    for (var t = 19990; t < 20010; t++) {
      expect(out[t], f32(ramp(t)), reason: 'frame $t');
    }
  });

  test('loops, seeks and scrub work in timeline frames', () {
    openTake(sr * 2, sine);
    PocketAudio.setClips([
      PlayClip(60000, 80000, gain: 1.0),
      PlayClip(0, 20000, gain: 1.0),
    ]);
    PocketAudio.setLoop(15000, 25000); // spans the join
    PocketAudio.seek(15000);
    PocketAudio.playing = true;
    final out = renderAll(40000);
    expect(maxJump(out.sublist(300)), lessThan(sineStep * 1.5));
    expect(PocketAudio.playbackPosition, inInclusiveRange(15000 - 240, 25000));
  });

  test('a shorter list pulls the position and loop back inside', () {
    openTake(sr, sine);
    PocketAudio.setLoop(30000, 40000);
    PocketAudio.seek(45000);
    PocketAudio.setClips([PlayClip(0, 10000, gain: 1.0)]);
    expect(PocketAudio.loop, isNull);
    expect(PocketAudio.playbackPosition, lessThanOrEqualTo(10000));
    // Empty list = whole recording again (revert).
    expect(PocketAudio.setClips(const []), sr);
  });

  test('zero-crossing snap finds the nearest sign change', () {
    openTake(sr, sine);
    // 440 Hz at 48 kHz: zero crossings every 48000/880 ≈ 54.5 frames.
    final z = PocketAudio.zeroCrossing(1000, radius: 240);
    expect((z - 1000).abs(), lessThanOrEqualTo(28));
    expect(sine(z - 1).sign != sine(z).sign || sine(z) == 0, isTrue);
    // Silence has no crossings: returns the input.
    openTake(sr, (_) => 0.25);
    expect(PocketAudio.zeroCrossing(1000), 1000);
  });
}
