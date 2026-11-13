// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:math' as math;

import 'package:pocket_audio/pocket_audio.dart';
import 'package:test/test.dart';

void main() {
  test('version names miniaudio', () {
    expect(PocketAudio.version, contains('miniaudio 0.11.25'));
  });

  group('offline tone', () {
    const sampleRate = 48000;

    test('fills every channel with the same sample', () {
      final out = PocketAudio.renderToneOffline(
        frames: 480,
        channels: 2,
        sampleRate: sampleRate,
        frequencyHz: 440,
        amplitude: 0.5,
      );
      for (var i = 0; i < 480; i++) {
        expect(out[2 * i], out[2 * i + 1]);
      }
    });

    test('ramps in from silence instead of clicking', () {
      final out = PocketAudio.renderToneOffline(
        frames: sampleRate,
        channels: 1,
        sampleRate: sampleRate,
        frequencyHz: 440,
        amplitude: 0.5,
      );
      expect(out[0], 0);
      // Slew limit is full scale per 10 ms, so after 1 ms |sample| <= 0.1.
      for (var i = 0; i < 48; i++) {
        expect(out[i].abs(), lessThanOrEqualTo(0.1 + 1e-6));
      }
      // After the ramp the peak is the requested amplitude.
      final tail = out.sublist(sampleRate ~/ 2);
      expect(tail.reduce(math.max), closeTo(0.5, 1e-3));
      expect(tail.reduce(math.min), closeTo(-0.5, 1e-3));
    });

    test('has the requested frequency', () {
      final out = PocketAudio.renderToneOffline(
        frames: sampleRate,
        channels: 1,
        sampleRate: sampleRate,
        frequencyHz: 440,
        amplitude: 1,
      );
      var upwardCrossings = 0;
      for (var i = 1; i < out.length; i++) {
        if (out[i - 1] < 0 && out[i] >= 0) upwardCrossings++;
      }
      expect(upwardCrossings, inInclusiveRange(439, 441));
    });

    test('silent at zero amplitude', () {
      final out = PocketAudio.renderToneOffline(
        frames: 4800,
        channels: 2,
        sampleRate: sampleRate,
        frequencyHz: 440,
        amplitude: 0,
      );
      expect(out.every((s) => s == 0), isTrue);
    });
  });
}
