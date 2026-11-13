// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Recorder tests: feed synthetic "microphone" input through the same entry
// point the audio callback uses, then read the WAV back with an independent
// parser. See wiki/features/record.md.

import 'dart:io';
import 'dart:typed_data';

import 'package:pocket_audio/pocket_audio.dart';
import 'package:test/test.dart';

const sr = 48000;

/// Minimal independent WAV reader (does not share code with the C++ writer).
class Wav {
  Wav(Uint8List bytes) : data = ByteData.sublistView(bytes) {
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
    var p = 12;
    while (p + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(p, p + 4));
      final size = data.getUint32(p + 4, Endian.little);
      if (id == 'fmt ') {
        format = data.getUint16(p + 8, Endian.little);
        channels = data.getUint16(p + 10, Endian.little);
        sampleRate = data.getUint32(p + 12, Endian.little);
        bits = data.getUint16(p + 22, Endian.little);
      } else if (id == 'fact') {
        factFrames = data.getUint32(p + 8, Endian.little);
      } else if (id == 'data') {
        dataOffset = p + 8;
        dataBytes = size;
        break;
      }
      p += 8 + size + (size & 1);
    }
    riffSize = data.getUint32(4, Endian.little);
  }

  final ByteData data;
  late int format, channels, sampleRate, bits, factFrames, riffSize;
  int dataOffset = -1, dataBytes = 0;

  int get frames => dataBytes ~/ 4;
  double sample(int i) => data.getFloat32(dataOffset + 4 * i, Endian.little);
}

/// Deterministic test signal: distinct value per sample index, within ±0.5.
double signal(int i) => ((i * 7919) % 20001 - 10000) / 20000.0;

final _f = Float32List(1);

/// Rounds to float32, as stored in the file.
double f32(double x) => (_f..[0] = x)[0];

Float32List chunk(int start, int frames) =>
    Float32List.fromList([for (var i = 0; i < frames; i++) signal(start + i)]);

Future<void> waitForWritten(int frames) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (PocketAudio.framesWritten < frames) {
    if (DateTime.now().isAfter(deadline)) {
      fail('writer stuck at ${PocketAudio.framesWritten} / $frames frames');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ps_rec_');
    PocketAudio.inputGain = 1.0;
    // Let gain smoothing settle on unity.
    PocketAudio.processInput(Float32List(sr));
    PocketAudio.takeInputPeak();
    PocketAudio.resetClip();
  });

  tearDown(() {
    if (PocketAudio.isRecording) PocketAudio.endRecording();
    dir.deleteSync(recursive: true);
  });

  test('records input bit-exactly into a mono float WAV', () {
    final wavPath = '${dir.path}/take.wav';
    final peaksPath = '${dir.path}/take.peaks';
    PocketAudio.beginRecording(wavPath);
    expect(PocketAudio.isRecording, isTrue);
    const total = sr * 3 + 123; // not a multiple of the block size
    for (var i = 0; i < total; i += 480) {
      PocketAudio.processInput(chunk(i, (total - i).clamp(0, 480)));
    }
    PocketAudio.endRecording(peaksPath: peaksPath);
    expect(PocketAudio.isRecording, isFalse);
    expect(PocketAudio.droppedFrames, 0);

    final wav = Wav(File(wavPath).readAsBytesSync());
    expect(wav.format, 3, reason: 'IEEE float');
    expect(wav.channels, 1);
    expect(wav.sampleRate, sr);
    expect(wav.bits, 32);
    expect(wav.frames, total);
    expect(wav.factFrames, total);
    expect(wav.riffSize, File(wavPath).lengthSync() - 8);
    for (var i = 0; i < total; i++) {
      if (wav.sample(i) != f32(signal(i))) {
        fail('sample $i differs');
      }
    }

    // Peaks file: header + one (min, max) pair per 256 frames, last partial.
    final peaks = ByteData.sublistView(File(peaksPath).readAsBytesSync());
    expect(
      String.fromCharCodes(peaks.buffer.asUint8List(peaks.offsetInBytes, 4)),
      'PSPK',
    );
    expect(peaks.getUint32(4, Endian.little), 1);
    expect(peaks.getUint32(8, Endian.little), 256);
    final blocks = peaks.getUint32(12, Endian.little);
    expect(blocks, (total + 255) ~/ 256);
    for (final b in [0, 7, blocks - 1]) {
      var lo = double.infinity, hi = double.negativeInfinity;
      for (var i = b * 256; i < (b + 1) * 256 && i < total; i++) {
        lo = lo < wav.sample(i) ? lo : wav.sample(i);
        hi = hi > wav.sample(i) ? hi : wav.sample(i);
      }
      expect(peaks.getFloat32(16 + 8 * b, Endian.little), lo);
      expect(peaks.getFloat32(20 + 8 * b, Endian.little), hi);
    }
  });

  test('pause skips input; resume appends to the same take', () {
    final wavPath = '${dir.path}/take.wav';
    PocketAudio.beginRecording(wavPath);
    PocketAudio.processInput(chunk(0, 1000));
    PocketAudio.paused = true;
    expect(PocketAudio.isPaused, isTrue);
    PocketAudio.processInput(Float32List(5000)..fillRange(0, 5000, 0.9));
    PocketAudio.paused = false;
    PocketAudio.processInput(chunk(1000, 1000));
    PocketAudio.endRecording();

    final wav = Wav(File(wavPath).readAsBytesSync());
    expect(wav.frames, 2000);
    for (var i = 0; i < 2000; i++) {
      expect(wav.sample(i), f32(signal(i)));
    }
  });

  test(
    'file on disk is a valid WAV while still recording (crash safety)',
    () async {
      final wavPath = '${dir.path}/take.wav';
      PocketAudio.beginRecording(wavPath);
      for (var i = 0; i < sr * 2; i += 480) {
        PocketAudio.processInput(chunk(i, 480));
      }
      await waitForWritten(sr * 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Read as a crash would leave it: no endRecording().
      final wav = Wav(File(wavPath).readAsBytesSync());
      expect(
        wav.frames,
        greaterThanOrEqualTo(sr),
        reason: 'header is patched at least once per second of audio',
      );
      expect(wav.frames, lessThanOrEqualTo(sr * 2));
      expect(wav.sample(wav.frames - 1), f32(signal(wav.frames - 1)));
      PocketAudio.endRecording();
    },
  );

  test('live peaks follow the recording', () async {
    PocketAudio.beginRecording('${dir.path}/take.wav');
    PocketAudio.processInput(Float32List(256 * 10)..fillRange(0, 2560, 0.25));
    await waitForWritten(2560);
    expect(PocketAudio.livePeakBlockCount, 10);
    final p = PocketAudio.copyLivePeaks(8, 100);
    expect(p, [0.25, 0.25, 0.25, 0.25]);
    expect(PocketAudio.copyLivePeaks(10, 5), isEmpty);
    PocketAudio.endRecording();
  });

  test('gain, level meter and clip flag', () {
    PocketAudio.processInput(Float32List(100)..fillRange(0, 100, 0.4));
    expect(PocketAudio.takeInputPeak(), closeTo(0.4, 1e-6));
    expect(PocketAudio.takeInputPeak(), 0, reason: 'reading resets');
    expect(PocketAudio.clipped, isFalse);

    PocketAudio.inputGain = 3.0;
    PocketAudio.processInput(
      Float32List(sr ~/ 10)..fillRange(0, sr ~/ 10, 0.4),
    );
    expect(PocketAudio.takeInputPeak(), closeTo(1.2, 1e-3));
    expect(PocketAudio.clipped, isTrue);
    PocketAudio.resetClip();
    expect(PocketAudio.clipped, isFalse);
  });

  test('gain changes are smoothed, not stepped', () {
    PocketAudio.inputGain = 2.0;
    PocketAudio.processInput(Float32List(48)..fillRange(0, 48, 0.25));
    // After 1 ms the gain has moved only part of the way.
    expect(PocketAudio.takeInputPeak(), lessThan(0.4));
  });

  test('gain returns exactly to unity after a change', () {
    PocketAudio.inputGain = 2.0;
    PocketAudio.processInput(Float32List(sr));
    PocketAudio.inputGain = 1.0;
    PocketAudio.processInput(Float32List(sr ~/ 2)); // 0.5 s to settle
    final wavPath = '${dir.path}/take.wav';
    PocketAudio.beginRecording(wavPath);
    PocketAudio.processInput(chunk(0, 1000));
    PocketAudio.endRecording();
    final wav = Wav(File(wavPath).readAsBytesSync());
    for (var i = 0; i < 1000; i++) {
      expect(wav.sample(i), f32(signal(i)), reason: 'sample $i');
    }
  });

  test('begin twice and end without a take are errors', () {
    PocketAudio.beginRecording('${dir.path}/a.wav');
    expect(
      () => PocketAudio.beginRecording('${dir.path}/b.wav'),
      throwsA(isA<PocketAudioException>()),
    );
    PocketAudio.endRecording();
    expect(
      () => PocketAudio.endRecording(),
      throwsA(isA<PocketAudioException>()),
    );
    expect(
      () => PocketAudio.beginRecording('${dir.path}/no/such/dir.wav'),
      throwsA(isA<PocketAudioException>()),
    );
  });

  test('30 minutes at 100x real time: no dropouts, every sample intact', () async {
    final wavPath = '${dir.path}/long.wav';
    const total = 30 * 60 * sr;
    const block = 480; // 10 ms, a typical callback size
    final start = DateTime.now();
    PocketAudio.beginRecording(wavPath);
    final buf = Float32List(sr);
    for (var sec = 0; sec < 30 * 60; sec++) {
      for (var i = 0; i < sr; i++) {
        buf[i] = signal(sec * sr + i);
      }
      for (var off = 0; off < sr; off += block) {
        PocketAudio.processInput(
          Float32List.sublistView(buf, off, off + block),
        );
      }
      // Pace at 100x real time: one second of audio every 10 ms.
      final due = start.add(Duration(milliseconds: (sec + 1) * 10));
      final wait = due.difference(DateTime.now());
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    PocketAudio.endRecording();
    expect(PocketAudio.droppedFrames, 0);
    expect(PocketAudio.writeError, isFalse);

    final file = File(wavPath).openSync();
    try {
      final header = file.readSync(58);
      final h = ByteData.sublistView(header);
      expect(h.getUint32(54, Endian.little), total * 4);
      expect(h.getUint32(46, Endian.little), total);
      // Check every sample, streaming 1 s at a time.
      for (var sec = 0; sec < 30 * 60; sec++) {
        final bytes = file.readSync(sr * 4);
        final got = Float32List.sublistView(
          Uint8List.fromList(bytes),
        ); // copy for alignment
        for (var i = 0; i < sr; i++) {
          if (got[i] != f32(signal(sec * sr + i))) {
            fail(
              'sample ${sec * sr + i} differs: got ${got[i]} want ${f32(signal(sec * sr + i))}',
            );
          }
        }
      }
    } finally {
      file.closeSync();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
