// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Tempo everywhere (M5b, wiki/decisions/d017-tempo-everywhere.md): the beat
// grid, tap tempo, saved settings, grids on takes and stacks, and the
// editor snapping splits to beats.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_audio/pocket_audio.dart';
import 'package:pocket_studio/edit/edit_list.dart';
import 'package:pocket_studio/screens/take_screen.dart';
import 'package:pocket_studio/stack/stack.dart';
import 'package:pocket_studio/takes/take_store.dart';
import 'package:pocket_studio/tempo/grid.dart';

void main() {
  group('grid', () {
    const g = Grid(bpm: 120, beatsPerBar: 3, downbeat: 1000);

    test('beats, bars and snapping', () {
      expect(g.beatFrames, 24000);
      expect(g.barFrames, 72000);
      expect(g.nearestBeat(1000 + 24000 * 2 + 11000), 1000 + 48000);
      expect(g.nearestBeat(1000 + 24000 * 2 + 13000), 1000 + 72000);
      expect(g.nearestBeat(0), 1000, reason: 'the grid runs both ways');
      expect(g.isBar(3), isTrue);
      expect(g.isBar(-3), isTrue);
      expect(g.isBar(4), isFalse);
    });

    test('lines: beats, bars marked; thinned to bars when dense', () {
      final l = g.lines(0, 100000);
      expect(l.map((x) => x.frame), [1000, 25000, 49000, 73000, 97000]);
      expect(l.map((x) => x.bar), [true, false, false, true, false]);
      final dense = g.lines(0, 48000 * 600, maxLines: 100);
      expect(dense.length, lessThanOrEqualTo(100));
      expect(dense.every((x) => x.bar), isTrue);
    });

    test('scaled through a time ratio: faster beats, higher BPM', () {
      final s = g.scaled(1.25);
      expect(s.bpm, 150);
      expect(s.beatFrames, closeTo(24000 / 1.25, 1e-9));
      expect(s.downbeat, 800);
    });

    test('JSON round trip; junk is no grid', () {
      expect(Grid.fromJson(g.toJson()), g);
      expect(Grid.fromJson(null), isNull);
      expect(Grid.fromJson({'bpm': 0}), isNull);
    });
  });

  test('tap tempo: average of the taps; a long pause starts again', () {
    final t = TapTempo();
    expect(t.tap(0), isNull);
    expect(t.tap(500000), closeTo(120, 1e-9));
    expect(t.tap(1000000), closeTo(120, 1e-9));
    expect(t.tap(1600000), closeTo(60 / (1.6 / 3), 1e-6));
    expect(t.tap(5000000), isNull, reason: 'over 2 s: a new count');
    expect(t.tap(5250000), closeTo(240, 1e-9));
  });

  test('settings save and load', () {
    final dir = Directory.systemTemp.createTempSync('ps_tempo_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/tempo.json');
    expect(TempoSettings.load(f).bpm, 120, reason: 'defaults');
    const s = TempoSettings(
      bpm: 93.5,
      beatsPerBar: 6,
      beatUnit: 8,
      countInBars: 2,
      clickWhileRecording: true,
      recordWithTempo: true,
    );
    s.save(f);
    final l = TempoSettings.load(f);
    expect(l.grid(), s.grid());
    expect(l.countInBeats, 12);
    expect(l.clickWhileRecording, isTrue);
    expect(l.recordWithTempo, isTrue);
  });

  group('grid on takes and stacks', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ps_grid_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('a take with only a grid keeps it, and is not "edited"', () {
      final store = TakeStore(dir);
      final t = store.newTake();
      PocketAudio.beginRecording(t.wav);
      PocketAudio.processInput(Float32List(48000));
      PocketAudio.endRecording(peaksPath: t.peaks);
      final take = store.list().single;
      const g = Grid(bpm: 90, downbeat: 512);
      store.saveEdits(take, EditList.whole(take.frames).withGrid(g));
      expect(store.loadEdits(take.id, take.frames).grid, g);
      expect(store.list().single.edited, isFalse);
      // Edits keep the grid; removing it removes the file again.
      final cut = EditList.whole(take.frames).withGrid(g).split(1000);
      expect(cut.grid, g);
      store.saveEdits(take, EditList.whole(take.frames));
      expect(store.loadEdits(take.id, take.frames).grid, isNull);
    });

    test('stacks save their grid', () {
      final s = LayerStack('x', DateTime(2026), const [
        Layer('a'),
      ]).withGrid(const Grid(bpm: 100, beatsPerBar: 7, beatUnit: 8));
      final back = LayerStack.fromJsonString('x', s.toJsonString());
      expect(back, s);
      expect(back.grid!.signature, '7/8');
      expect(back.add(const Layer('b')).grid, s.grid);
    });
  });

  testWidgets('with a grid, split lands on the nearest beat', (tester) async {
    final dir = Directory.systemTemp.createTempSync('ps_snap_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = TakeStore(dir);
    late Take take;
    await tester.runAsync(() async {
      final t = store.newTake();
      PocketAudio.beginRecording(t.wav);
      PocketAudio.processInput(Float32List(96000)..fillRange(0, 96000, 0.3));
      PocketAudio.endRecording(peaksPath: t.peaks);
      take = store.list().single;
      store.saveEdits(
        take,
        EditList.whole(take.frames).withGrid(const Grid(bpm: 120)),
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: TakeScreen(store: store, take: take),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('120'), findsOneWidget, reason: 'the BPM chip');
    PocketAudio.seek(30000); // nearest beat: 24000
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('split')));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    final e = store.loadEdits(take.id, take.frames);
    expect(e.clips.map((c) => c.end).first, 24000);
    expect(e.grid, const Grid(bpm: 120));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Detect sets the grid from the audio', (tester) async {
    final dir = Directory.systemTemp.createTempSync('ps_det_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = TakeStore(dir);
    late Take take;
    await tester.runAsync(() async {
      // 10 s at 110 BPM: kicks on 1 and 3 (accent on 1), snares on 2 and 4,
      // starting 5000 frames in.
      const n = 480000, lead = 5000;
      const beat = 48000 * 60 / 110;
      final x = Float32List(n);
      final rnd = math.Random(3);
      for (var b = 0; lead + b * beat < n; b++) {
        final t = (lead + b * beat).round();
        for (var k = 0; k < 8000 && t + k < n; k++) {
          x[t + k] += b.isEven
              ? (b % 4 == 0 ? 0.9 : 0.6) *
                    math.exp(-k / 4000) *
                    math.sin(2 * math.pi * 55 * k / 48000)
              : math.exp(-k / 2500) *
                    (0.35 * (rnd.nextDouble() * 2 - 1) +
                        0.3 * math.sin(2 * math.pi * 185 * k / 48000));
        }
      }
      final t = store.newTake();
      PocketAudio.beginRecording(t.wav);
      PocketAudio.processInput(x);
      PocketAudio.endRecording(peaksPath: t.peaks);
      take = store.list().single;
    });
    await tester.pumpWidget(
      MaterialApp(
        home: TakeScreen(store: store, take: take),
      ),
    );
    Future<void> settle([int n = 10]) async {
      for (var i = 0; i < n; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await settle();
    await tester.tap(find.byKey(const Key('bpm')));
    await settle(3);
    await tester.tap(find.byKey(const Key('detect-tempo')));
    await settle(20);
    expect(find.textContaining('Detected 110 BPM'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tempo-done')));
    await settle(3);
    final g = store.loadEdits(take.id, take.frames).grid!;
    expect(g.bpm, closeTo(110, 0.1));
    final bar = g.barFrames;
    final off = ((g.downbeat - 5000) % bar + bar) % bar;
    expect(math.min(off, bar - off), lessThan(600));
    await tester.pumpWidget(const SizedBox());
  });
}
