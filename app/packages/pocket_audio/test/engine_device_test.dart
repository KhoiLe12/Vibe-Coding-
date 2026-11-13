// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'dart:io';

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

  test('records 2 s from the real microphone into a WAV', () async {
    final dir = Directory.systemTemp.createTempSync('ps_dev_');
    addTearDown(() => dir.deleteSync(recursive: true));
    PocketAudio.setTone(frequencyHz: 440, amplitude: 0);
    PocketAudio.start(input: true);
    expect(PocketAudio.hasInput, isTrue);

    final wav = '${dir.path}/mic.wav';
    PocketAudio.beginRecording(wav);
    await Future<void>.delayed(const Duration(seconds: 2));
    PocketAudio.endRecording(peaksPath: '${dir.path}/mic.peaks');
    PocketAudio.stop();

    final frames = (File(wav).lengthSync() - 58) ~/ 4;
    // ~2 s at 48 kHz, allowing for device start-up.
    expect(frames, inInclusiveRange(48000 * 3 ~/ 2, 48000 * 5 ~/ 2));
    expect(PocketAudio.droppedFrames, 0);
    // ignore: avoid_print
    print('mic take: $frames frames, input peak ${PocketAudio.takeInputPeak()}');
  });
}
