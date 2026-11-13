// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Latency probe against a simulated room with a known delay
// (wiki/decisions/d008-latency-gate-route.md).

import 'package:pocket_audio/pocket_audio.dart';
import 'package:test/test.dart';

void main() {
  // Smallest delay is one 256-frame block: the simulated room can only echo
  // what an earlier callback played (as on a real device).
  for (final delay in [256, 517, 1440, 9600]) {
    test('measures a $delay-frame round trip exactly', () {
      PocketAudio.simulateLatency(delayFrames: delay, seconds: 6);
      expect(PocketAudio.latencyInputOverflow, isFalse);
      final n = PocketAudio.latencyCount;
      expect(n, greaterThanOrEqualTo(9), reason: '~11 chirps in 6 s');
      expect(PocketAudio.latencyMissed, 0);
      for (final ms in PocketAudio.latencyResults(0, n)) {
        expect(ms, closeTo(delay * 1000 / 48000, 1e-3));
      }
    });
  }

  test('measures exactly under room noise (echo peak = noise peak)', () {
    PocketAudio.simulateLatency(
      delayFrames: 1000,
      seconds: 6,
      echoGain: 0.1,
      noise: 0.05,
    );
    final n = PocketAudio.latencyCount;
    expect(n, greaterThanOrEqualTo(9));
    expect(PocketAudio.latencyMissed, 0);
    for (final ms in PocketAudio.latencyResults(0, n)) {
      expect(ms, closeTo(1000 * 1000 / 48000, 1e-3));
    }
  });

  test('never reports a wrong value when the echo drowns in noise', () {
    PocketAudio.simulateLatency(
      delayFrames: 1000,
      seconds: 6,
      echoGain: 0.05,
      noise: 0.1,
    );
    final n = PocketAudio.latencyCount;
    expect(n + PocketAudio.latencyMissed, greaterThanOrEqualTo(9));
    for (final ms in PocketAudio.latencyResults(0, n)) {
      expect(
        ms,
        closeTo(1000 * 1000 / 48000, 1e-3),
        reason: 'accepted detections must be right; doubtful ones missed',
      );
    }
  });

  test('reports misses instead of guessing when nothing comes back', () {
    PocketAudio.simulateLatency(
      delayFrames: 1000,
      seconds: 6,
      echoGain: 0,
      noise: 0.05,
    );
    expect(PocketAudio.latencyCount, 0);
    expect(PocketAudio.latencyMissed, greaterThanOrEqualTo(9));
  });

  test('no OS-reported latency on the host', () {
    expect(PocketAudio.reportedLatency, isNull);
  });
}
