// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_audio/pocket_audio.dart';
import 'package:pocket_studio/main.dart';
import 'package:pocket_studio/takes/take_store.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('ps_app_'));
  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('empty inbox invites the first recording', (tester) async {
    final store = TakeStore(dir);
    await tester.pumpWidget(PocketStudioApp(openStore: () async => store));
    await tester.pump();
    expect(find.textContaining('No takes yet'), findsOneWidget);
    expect(find.byKey(const Key('new-take')), findsOneWidget);
  });

  testWidgets('lists takes recorded by the native core', (tester) async {
    final store = TakeStore(dir);
    // Record 1.5 s through the real C++ recorder (no microphone needed).
    await tester.runAsync(() async {
      final t = store.newTake();
      PocketAudio.beginRecording(t.wav);
      PocketAudio.processInput(Float32List(72000));
      PocketAudio.endRecording(peaksPath: t.peaks);
    });
    await tester.pumpWidget(PocketStudioApp(openStore: () async => store));
    await tester.pump();
    expect(find.text('00:01'), findsOneWidget);

    final takes = store.list();
    expect(takes.single.frames, 72000);
    final peaks = await tester.runAsync(() => store.loadPeaks(takes.single));
    expect(peaks!.blocks, (72000 + 255) ~/ 256);
  });

  test('missing peaks are rebuilt from the WAV', () async {
    final store = TakeStore(dir);
    final t = store.newTake();
    PocketAudio.beginRecording(t.wav);
    PocketAudio.processInput(Float32List(4096)..fillRange(0, 4096, 0.5));
    PocketAudio.endRecording(); // no peaks file, as after a crash
    final take = store.list().single;
    expect(take.peaks.existsSync(), isFalse);
    final peaks = await store.loadPeaks(take);
    expect(peaks.blocks, 16);
    expect(peaks.minMax.every((v) => v == 0.5), isTrue);
  });
}
