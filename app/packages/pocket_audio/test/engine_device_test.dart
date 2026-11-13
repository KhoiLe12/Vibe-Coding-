// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'package:pocket_audio/pocket_audio.dart';
import 'package:test/test.dart';

void main() {
  tearDown(PocketAudio.stop);

  test('opens the default output and serves callbacks', () async {
    PocketAudio.setTone(frequencyHz: 440, amplitude: 0); // silent
    PocketAudio.start();
    expect(PocketAudio.isRunning, isTrue);
    expect(PocketAudio.sampleRate, greaterThan(0));
    expect(() => PocketAudio.start(), throwsA(isA<PocketAudioException>()));

    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(PocketAudio.callbackCount, greaterThan(0));

    PocketAudio.stop();
    expect(PocketAudio.isRunning, isFalse);
    expect(PocketAudio.sampleRate, 0);
  });
}
