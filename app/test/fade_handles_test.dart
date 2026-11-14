// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Fade handles (human, 2026-11-14: a needle per clip was still clunky; fades
// sit at the start and end of the take or the selection): dragging a top
// corner of the waveform sets the fade.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_audio/pocket_audio.dart';
import 'package:pocket_studio/screens/take_screen.dart';
import 'package:pocket_studio/takes/take_store.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ps_handles_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> settle(WidgetTester tester, [int n = 15]) async {
    for (var i = 0; i < n; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<(TakeStore, Take)> open(WidgetTester tester) async {
    final store = TakeStore(dir);
    late Take take;
    await tester.runAsync(() async {
      final t = store.newTake();
      PocketAudio.beginRecording(t.wav);
      PocketAudio.processInput(Float32List(96000)..fillRange(0, 96000, 0.3));
      PocketAudio.endRecording(peaksPath: t.peaks);
      take = store.list().single;
    });
    await tester.pumpWidget(
      MaterialApp(
        home: TakeScreen(store: store, take: take),
      ),
    );
    await settle(tester);
    return (store, take);
  }

  Future<void> drag(WidgetTester tester, Offset from, Offset to) async {
    final g = await tester.startGesture(from);
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(Offset.lerp(from, to, i / 10)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await settle(tester, 5);
  }

  for (final fadeIn in [true, false]) {
    testWidgets('whole take: drag the ${fadeIn ? 'left' : 'right'} corner '
        'to fade ${fadeIn ? 'in' : 'out'}', (tester) async {
      final (store, take) = await open(tester);
      final box = tester.getRect(find.byKey(const Key('waveform')));
      // The handle hangs inside the corner; drag it to the middle (1 s).
      final corner = Offset(fadeIn ? box.left + 9 : box.right - 9, box.top + 9);
      await drag(tester, corner, Offset(box.center.dx, box.top + 9));

      final c = store.loadEdits(take.id, take.frames).clips.single;
      final frames = fadeIn ? c.fadeInFrames : c.fadeOutFrames;
      expect(frames, closeTo(48000, 1500));
      expect(fadeIn ? c.fadeOutFrames : c.fadeInFrames, 0);

      // Undo removes it in one step.
      await tester.tap(find.byKey(const Key('undo')));
      await settle(tester, 5);
      expect(
        store.loadEdits(take.id, take.frames).clips.single.hasFade,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('a drag elsewhere still scrubs, not fades', (tester) async {
    final (store, take) = await open(tester);
    final box = tester.getRect(find.byKey(const Key('waveform')));
    await drag(
      tester,
      Offset(box.left + box.width * 0.3, box.center.dy),
      Offset(box.left + box.width * 0.6, box.center.dy),
    );
    expect(store.loadEdits(take.id, take.frames).clips.single.hasFade, isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}
