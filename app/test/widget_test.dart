// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_audio/pocket_audio.dart';
import 'package:pocket_studio/edit/edit_list.dart';
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

  test('edits are saved per take and shown as the take length', () {
    final store = TakeStore(dir);
    final t = store.newTake();
    PocketAudio.beginRecording(t.wav);
    PocketAudio.processInput(Float32List(48000));
    PocketAudio.endRecording(peaksPath: t.peaks);
    var take = store.list().single;
    expect(take.edited, isFalse);

    final edits = EditList.whole(take.frames).delete(0, 12000);
    store.saveEdits(take, edits);
    take = store.list().single;
    expect(take.edited, isTrue);
    expect(take.editedFrames, 36000);
    expect(store.loadEdits(take.id, take.frames), edits);

    // Reverting to the whole recording removes the edits file.
    store.saveEdits(take, EditList.whole(take.frames));
    expect(store.editsFile(take.id).existsSync(), isFalse);
    expect(store.list().single.edited, isFalse);

    // Deleting a take deletes its edits too.
    store.saveEdits(take, edits);
    store.delete(take);
    expect(store.editsFile(take.id).existsSync(), isFalse);
  });

  test('a damaged edits file falls back to the whole recording', () {
    final store = TakeStore(dir);
    final t = store.newTake();
    PocketAudio.beginRecording(t.wav);
    PocketAudio.processInput(Float32List(4800));
    PocketAudio.endRecording(peaksPath: t.peaks);
    final take = store.list().single;
    store.editsFile(take.id).writeAsStringSync('{not json');
    expect(store.loadEdits(take.id, take.frames).isWhole(take.frames), isTrue);
  });
}
