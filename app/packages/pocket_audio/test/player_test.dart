// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Player tests: record a take with the recorder, then run the player's
// audio-thread code offline and compare. See wiki/components/audio-engine.md.

import 'dart:io';
import 'dart:typed_data';

import 'package:pocket_audio/pocket_audio.dart';
import 'package:test/test.dart';

const sr = 48000;
final _f = Float32List(1);
double f32(double x) => (_f..[0] = x)[0];
double signal(int i) => ((i * 7919) % 20001 - 10000) / 20000.0;

late Directory dir;

String recordTake(int frames, {String name = 'take'}) {
  final path = '${dir.path}/$name.wav';
  PocketAudio.beginRecording(path);
  for (var i = 0; i < frames; i += 480) {
    final n = (frames - i).clamp(0, 480);
    PocketAudio.processInput(
        Float32List.fromList([for (var k = 0; k < n; k++) signal(i + k)]));
  }
  PocketAudio.endRecording(peaksPath: '${dir.path}/$name.peaks');
  return path;
}

void main() {
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ps_play_');
    PocketAudio.inputGain = 1.0;
    PocketAudio.processInput(Float32List(sr));
  });
  tearDown(() {
    PocketAudio.closeTake();
    dir.deleteSync(recursive: true);
  });

  test('opens paused at 0 and outputs nothing until played', () {
    PocketAudio.openTake(recordTake(sr));
    expect(PocketAudio.takeLength, sr);
    expect(PocketAudio.isPlaying, isFalse);
    final out = PocketAudio.renderPlayerOffline(512);
    expect(out.every((s) => s == 0), isTrue);
    expect(PocketAudio.playbackPosition, 0);
  });

  test('plays the take on every channel, with a 5 ms fade-in', () {
    PocketAudio.openTake(recordTake(sr));
    PocketAudio.playing = true;
    final out = PocketAudio.renderPlayerOffline(4800);
    // Fade-in: |out| never exceeds the source and starts quiet.
    expect(out[0].abs(), lessThan(0.01));
    for (var i = 0; i < 4800; i++) {
      expect(out[2 * i], out[2 * i + 1], reason: 'mono on both channels');
      expect(out[2 * i].abs(), lessThanOrEqualTo(signal(i).abs() + 1e-6));
    }
    // After the ramp (240 frames) samples are exact.
    for (var i = 240; i < 4800; i++) {
      expect(out[2 * i], f32(signal(i)), reason: 'frame $i');
    }
    expect(PocketAudio.playbackPosition, 4800);
  });

  test('pause fades out and holds the position; resume continues', () {
    PocketAudio.openTake(recordTake(sr));
    PocketAudio.playing = true;
    PocketAudio.renderPlayerOffline(1000);
    PocketAudio.playing = false;
    final fade = PocketAudio.renderPlayerOffline(1000);
    final held = PocketAudio.playbackPosition;
    expect(held, lessThan(2000), reason: 'stops consuming once silent');
    expect(fade[2 * 999], 0);
    PocketAudio.renderPlayerOffline(1000);
    expect(PocketAudio.playbackPosition, held);
    PocketAudio.playing = true;
    PocketAudio.renderPlayerOffline(1000);
    expect(PocketAudio.playbackPosition, held + 1000);
  });

  test('stops at the end and reports finished; seek(0) replays', () {
    PocketAudio.openTake(recordTake(1000));
    PocketAudio.playing = true;
    final out = PocketAudio.renderPlayerOffline(2000);
    expect(PocketAudio.playbackFinished, isTrue);
    expect(PocketAudio.isPlaying, isFalse);
    expect(PocketAudio.playbackPosition, 1000);
    expect(out.sublist(2000).every((s) => s == 0), isTrue);

    PocketAudio.seek(0);
    expect(PocketAudio.playbackFinished, isFalse);
    PocketAudio.playing = true;
    PocketAudio.renderPlayerOffline(500);
    expect(PocketAudio.playbackPosition, 500);
  });

  test('seek starts from the requested frame', () {
    PocketAudio.openTake(recordTake(sr));
    PocketAudio.seek(10000);
    PocketAudio.playing = true;
    final out = PocketAudio.renderPlayerOffline(1000);
    expect(out[2 * 500], f32(signal(10500)));
    expect(PocketAudio.playbackPosition, 11000);
  });

  test('a take cut short by a crash plays in full and gets peaks rebuilt',
      () async {
    final path = '${dir.path}/crash.wav';
    PocketAudio.beginRecording(path);
    PocketAudio.processInput(
        Float32List.fromList([for (var i = 0; i < sr + 5000; i++) signal(i)]));
    while (PocketAudio.framesWritten < sr + 5000) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // Simulate the crash: copy the file as it is now, header possibly stale.
    final crashed = '${dir.path}/crashed.wav';
    File(path).copySync(crashed);
    PocketAudio.endRecording();

    PocketAudio.openTake(crashed);
    expect(PocketAudio.takeLength, sr + 5000,
        reason: 'length from file size, not the stale header');

    PocketAudio.buildPeaks(crashed, '${dir.path}/crashed.peaks');
    final rebuilt = File('${dir.path}/crashed.peaks').readAsBytesSync();
    PocketAudio.closeTake();
    recordTake(sr + 5000, name: 'clean');
    expect(rebuilt, File('${dir.path}/clean.peaks').readAsBytesSync(),
        reason: 'rebuilt peaks match the recorder\'s own');
  });

  test('rejects files that are not mono float WAVs', () {
    File('${dir.path}/bad.wav').writeAsStringSync('not a wav');
    expect(() => PocketAudio.openTake('${dir.path}/bad.wav'),
        throwsA(isA<PocketAudioException>()));
  });
}
