// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// M2 navigation: seamless loops, click-free seeks, tape-style scrub and
// shuttle (wiki/features/playback-and-scrub.md, d009, d011). A recorded sine
// makes clicks measurable: the largest jump between neighbouring samples of a
// 440 Hz sine at amplitude 0.5 is 0.5·2π·440/48000 ≈ 0.029.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pocket_audio/pocket_audio.dart';
import 'package:test/test.dart';

const sr = 48000;
const sineStep = 0.5 * 2 * math.pi * 440 / sr;

late Directory dir;

String recordSine(int frames) {
  final path = '${dir.path}/sine.wav';
  PocketAudio.beginRecording(path);
  final s = Float32List(frames);
  for (var i = 0; i < frames; i++) {
    s[i] = 0.5 * math.sin(2 * math.pi * 440 * i / sr);
  }
  PocketAudio.processInput(s);
  PocketAudio.endRecording();
  return path;
}

/// Mono view of a stereo render.
Float32List mono(Float32List stereo) => Float32List.fromList([
  for (var i = 0; i < stereo.length; i += 2) stereo[i],
]);

double maxJump(Float32List x) {
  var m = 0.0;
  for (var i = 1; i < x.length; i++) {
    m = math.max(m, (x[i] - x[i - 1]).abs());
  }
  return m;
}

Float32List render(int frames) {
  // Render in 256-frame callbacks, like a device would.
  final out = Float32List(frames);
  for (var i = 0; i < frames; i += 256) {
    final n = math.min(256, frames - i);
    out.setAll(i, mono(PocketAudio.renderPlayerOffline(n)));
  }
  return out;
}

void main() {
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ps_nav_');
    PocketAudio.inputGain = 1.0;
    PocketAudio.processInput(Float32List(sr));
  });
  tearDown(() {
    PocketAudio.closeTake();
    dir.deleteSync(recursive: true);
  });

  group('loop', () {
    test('period is exactly end - start, and the wrap does not click', () {
      PocketAudio.openTake(recordSine(sr * 2));
      // Boundaries deliberately at awkward sine phases.
      const start = 10007, end = 23011;
      PocketAudio.setLoop(start, end);
      expect(PocketAudio.loop, (start: start, end: end));
      PocketAudio.seek(start);
      PocketAudio.playing = true;
      final out = render(sr * 2);
      // After the first wrap the output repeats with the loop period.
      const period = end - start;
      for (var i = period; i < out.length - period; i += 97) {
        expect(out[i + period], closeTo(out[i], 1e-6), reason: 'frame $i');
      }
      // No jump larger than the sine's own (plus a small crossfade margin).
      expect(maxJump(out.sublist(1000)), lessThan(sineStep * 1.5));
      final pos = PocketAudio.playbackPosition;
      expect(pos, inInclusiveRange(start - 240, end));
    });

    test('clearing the loop plays on past the end point', () {
      PocketAudio.openTake(recordSine(sr));
      PocketAudio.setLoop(1000, 5000);
      PocketAudio.clearLoop();
      expect(PocketAudio.loop, isNull);
      PocketAudio.playing = true;
      render(8000);
      expect(PocketAudio.playbackPosition, 8000);
    });
  });

  test('seeking while playing crossfades instead of clicking', () {
    PocketAudio.openTake(recordSine(sr * 2));
    PocketAudio.playing = true;
    final a = render(4000);
    PocketAudio.seek(30011);
    final b = render(4000);
    final joined = Float32List.fromList([...a, ...b]);
    expect(maxJump(joined.sublist(1000)), lessThan(sineStep * 1.5));
    // Seek lands on the next callback: position is past the target already.
    expect(PocketAudio.playbackPosition, 30011 + 4000);
  });

  group('tape-style scrub', () {
    test('chases the finger forwards and slows to a stop', () {
      PocketAudio.openTake(recordSine(sr * 4));
      PocketAudio.seek(sr);
      render(256);
      PocketAudio.beginScrub();
      expect(PocketAudio.isScrubbing, isTrue);
      PocketAudio.scrubTarget = sr * 1.5; // finger moved 0.5 s ahead
      var last = PocketAudio.playbackPosition;
      for (var k = 0; k < 40; k++) {
        render(1200);
        final now = PocketAudio.playbackPosition;
        expect(now, greaterThanOrEqualTo(last), reason: 'only moves forward');
        last = now;
      }
      expect(last, closeTo(sr * 1.5, 50), reason: 'arrived at the finger');
      // Finger still: the tape has stopped, so it is quiet.
      final still = render(2400);
      expect(still.map((v) => v.abs()).reduce(math.max), lessThan(0.01));
    });

    test('plays backwards when the finger moves back', () {
      PocketAudio.openTake(recordSine(sr * 4));
      PocketAudio.seek(sr * 2);
      render(256);
      PocketAudio.beginScrub();
      PocketAudio.scrubTarget = sr * 1.0;
      final heard = render(sr ~/ 4);
      expect(PocketAudio.playbackPosition, lessThan(sr * 2 - 1000));
      expect(
        heard.map((v) => v.abs()).reduce(math.max),
        greaterThan(0.2),
        reason: 'audible while moving',
      );
      expect(maxJump(heard), lessThan(sineStep * kMaxSpeed * 1.2));
    });

    test(
      'ending a scrub resumes playback where the tape is, if it was playing',
      () {
        PocketAudio.openTake(recordSine(sr * 4));
        PocketAudio.playing = true;
        render(2400);
        PocketAudio.beginScrub();
        PocketAudio.scrubTarget = sr * 1.0;
        render(sr); // long enough to arrive
        PocketAudio.endScrub();
        final after = render(4800);
        expect(PocketAudio.isScrubbing, isFalse);
        expect(PocketAudio.isPlaying, isTrue);
        expect(PocketAudio.playbackPosition, closeTo(sr * 1 + 4800, 50));
        expect(maxJump(after), lessThan(sineStep * kMaxSpeed * 1.2));
      },
    );

    test(
      'letting go mid-flight stays where the tape is, not at the finger',
      () {
        PocketAudio.openTake(recordSine(sr * 30));
        PocketAudio.beginScrub();
        PocketAudio.scrubTarget = sr * 25.0; // far away: tape can't keep up
        render(4800);
        final heard = PocketAudio.playbackPosition;
        expect(heard, lessThan(sr * 2), reason: 'tape still far behind');
        PocketAudio.endScrub();
        render(4800);
        expect(PocketAudio.playbackPosition, closeTo(heard, 2 * sr * 0.1 * 8));
        expect(PocketAudio.playbackPosition, lessThan(sr * 5));
      },
    );

    test('ending a scrub while paused stays paused where it stopped', () {
      PocketAudio.openTake(recordSine(sr * 4));
      PocketAudio.beginScrub();
      PocketAudio.scrubTarget = sr * 2.0;
      render(sr); // long enough to arrive
      PocketAudio.endScrub();
      render(4800);
      expect(PocketAudio.isPlaying, isFalse);
      expect(PocketAudio.playbackPosition, closeTo(sr * 2, 50));
    });

    test('shuttle rewinds at a steady multiple of real time', () {
      PocketAudio.openTake(recordSine(sr * 4));
      PocketAudio.seek(sr * 3);
      render(256);
      PocketAudio.beginScrub();
      PocketAudio.shuttle = -4.0;
      render(sr ~/ 2); // 0.5 s → about 2 s of tape backwards
      final pos = PocketAudio.playbackPosition;
      expect(pos, inInclusiveRange(sr * 1, sr * 3 - sr * 3 ~/ 2));
      PocketAudio.endScrub();
      render(256);
      expect(PocketAudio.playbackPosition, closeTo(pos, 4000));
    });
  });
}

/// Mirrors kMaxSpeed in player.cpp: fastest scrub speed (× real time).
const kMaxSpeed = 8.0;
