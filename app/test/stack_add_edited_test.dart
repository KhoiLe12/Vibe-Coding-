// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Repro attempt: adding an edited take to a stack showed an error until the
// stack was reopened (human, 2026-11-14).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_audio/pocket_audio.dart';
import 'package:pocket_studio/edit/edit_list.dart';
import 'package:pocket_studio/screens/stack_screen.dart';
import 'package:pocket_studio/stack/stack.dart';
import 'package:pocket_studio/takes/take_store.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ps_sae_'));
  tearDown(() => dir.deleteSync(recursive: true));

  for (final kind in ['chopped', 'tuned', 'faded+reversed', 'no peaks']) {
    testWidgets('adding a $kind take plays it at once', (tester) async {
      final store = TakeStore(dir);
      late Take take;
      await tester.runAsync(() async {
        final t = store.newTake();
        PocketAudio.beginRecording(t.wav);
        PocketAudio.processInput(Float32List(48000)..fillRange(0, 48000, 0.3));
        PocketAudio.endRecording(
          peaksPath: kind == 'no peaks' ? null : t.peaks,
        );
        take = store.list().single;
        var e = EditList.whole(take.frames).delete(0, 4800);
        if (kind == 'tuned') e = e.withTune(const Tune(semitones: 3));
        if (kind == 'faded+reversed') {
          e = e.reverse(0, 20000).setFadeOut(1, 9000);
        }
        store.saveEdits(take, e);
      });
      final stack = store.newStack();
      store.saveStack(stack);
      await tester.pumpWidget(
        MaterialApp(
          home: StackScreen(store: store, stack: stack),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('add-take')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ListTile).first);
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.textContaining('Missing take'), findsNothing);
      expect(find.textContaining('Could not'), findsNothing);
      expect(find.textContaining('Layer 1'), findsOneWidget);
      expect(PocketAudio.takeLength, greaterThan(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('coming back from editing a layer leaves the stack playable '
      '(the editor closing late used to close the stack\'s player)', (
    tester,
  ) async {
    final store = TakeStore(dir);
    late Take take;
    await tester.runAsync(() async {
      final t = store.newTake();
      PocketAudio.beginRecording(t.wav);
      PocketAudio.processInput(Float32List(48000)..fillRange(0, 48000, 0.3));
      PocketAudio.endRecording(peaksPath: t.peaks);
      take = store.list().single;
    });
    final stack = store.newStack().add(Layer(take.id));
    store.saveStack(stack);
    await tester.pumpWidget(
      MaterialApp(
        home: StackScreen(store: store, stack: stack),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(PocketAudio.takeLength, 48000);
    await tester.tap(find.byKey(const Key('edit-layer-0')));
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byKey(const Key('waveform')), findsOneWidget);
    await tester.pageBack();
    // Let the stack reload while the editor's exit transition runs.
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byKey(const Key('waveform')), findsNothing);
    expect(PocketAudio.takeLength, 48000, reason: 'stack still open');
    await tester.pumpWidget(const SizedBox());
  });
}
