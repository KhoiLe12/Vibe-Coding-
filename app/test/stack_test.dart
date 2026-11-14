// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_audio/pocket_audio.dart';
import 'package:pocket_studio/edit/edit_list.dart';
import 'package:pocket_studio/stack/bounce.dart';
import 'package:pocket_studio/stack/stack.dart';
import 'package:pocket_studio/takes/take_store.dart';

void main() {
  final t0 = DateTime(2026, 11, 14);

  test('layers stay where they are put; silence at the start is allowed', () {
    final s = LayerStack('s', t0, const [
      Layer('a', offset: 500),
      Layer('b', offset: 800),
    ]);
    expect([for (final l in s.layers) l.offset], [500, 800]);
    // Sliding a layer before the start stops it at 0; the others stay.
    final slid = s.replace(1, s.layers[1].copyWith(offset: -200));
    expect([for (final l in slid.layers) l.offset], [500, 0]);
  });

  test('gains follow mute and solo', () {
    final s = LayerStack('s', t0, const [
      Layer('a', volume: 0.5),
      Layer('b', muted: true),
      Layer('c'),
    ]);
    expect(s.gains, [0.5, 0.0, 1.0]);
    final solo = s.replace(2, s.layers[2].copyWith(solo: true));
    expect(solo.gains, [0.0, 0.0, 1.0]);
  });

  test('every stack change is undoable (History<LayerStack>)', () {
    final h = History(LayerStack('s', t0, const []));
    h.push('Add layer', h.current.add(const Layer('a')));
    h.push('Add layer', h.current.add(const Layer('b')));
    h.push(
      'Slide',
      h.current.replace(1, h.current.layers[1].copyWith(offset: 4800)),
    );
    h.push(
      'Volume',
      h.current.replace(0, h.current.layers[0].copyWith(volume: 0.3)),
    );
    h.push('Remove layer', h.current.remove(0));
    expect(h.current.layers.single.takeId, 'b');
    for (var k = 0; k < 5; k++) {
      h.undo();
    }
    expect(h.current.layers, isEmpty);
    expect(h.canUndo, isFalse);
  });

  test('JSON round trip; the stack limit is the engine track limit', () {
    var s = LayerStack('s', t0, const [
      Layer('a', offset: 0, volume: 0.7, solo: true),
    ]);
    expect(LayerStack.fromJsonString('s', s.toJsonString()), s);
    for (var k = 0; k < 20; k++) {
      s = s.add(Layer('x$k'));
    }
    expect(s.layers.length, LayerStack.maxLayers);
  });

  test('store: stacks are saved; deleting a take removes its layer', () {
    final dir = Directory.systemTemp.createTempSync('ps_stk_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = TakeStore(dir);
    final t = store.newTake();
    PocketAudio.beginRecording(t.wav);
    PocketAudio.processInput(Float32List(4800));
    PocketAudio.endRecording(peaksPath: t.peaks);
    final take = store.list().single;
    var s = store.newStack();
    s = s.add(Layer(take.id)).add(const Layer('other'));
    store.saveStack(s);
    expect(store.listStacks().single, s);
    expect(store.takesInStacks(), {take.id, 'other'});
    store.delete(take);
    expect(store.listStacks().single.layers.single.takeId, 'other');
  });

  test(
    'bounce runs on a background isolate (was "object is unsendable")',
    () async {
      final dir = Directory.systemTemp.createTempSync('ps_bnc_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = TakeStore(dir);
      final t = store.newTake();
      PocketAudio.beginRecording(t.wav);
      PocketAudio.processInput(Float32List(4800)..fillRange(0, 4800, 0.25));
      PocketAudio.endRecording(peaksPath: t.peaks);
      PocketAudio.openStack();
      PocketAudio.setStack([
        StackTrack(t.wav, 0, const [(start: 0, end: 4800, gain: 1.0)]),
      ]);
      final out = '${dir.path}/mix.wav';
      await bounceStackInBackground(out);
      expect((File(out).lengthSync() - 58) ~/ 4, 4800);
      PocketAudio.closeTake();
    },
  );

  test('whole-stack editing: the mix is re-made when the stack changes; '
      'edits are kept by stack and clamped to a shorter mix', () {
    final dir = Directory.systemTemp.createTempSync('ps_mix_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = TakeStore(dir);
    var s = store.newStack().add(const Layer('a'));
    final p1 = store.stackMixPath(s);
    expect(store.stackMixPath(s), p1, reason: 'stable while unchanged');
    s = s.add(const Layer('b', offset: 100));
    expect(store.stackMixPath(s), isNot(p1), reason: 'arrangement changed');
    final p2 = store.stackMixPath(s);
    store
        .editsFile('a')
        .writeAsStringSync(EditList.whole(1000).delete(0, 10).toJsonString());
    expect(store.stackMixPath(s), isNot(p2), reason: "a layer's take edited");

    // A mix of 4800 frames; the stack's edits reach past a shorter mix.
    final mixPath = store.stackMixPath(s);
    File(mixPath).writeAsBytesSync(Uint8List(58 + 4800 * 4));
    final mix = store.stackMixTake(s, mixPath);
    expect(mix.editsId, s.id);
    store.saveEdits(
      mix,
      EditList([const Clip(0, 1000), const Clip(3000, 6000)]),
    );
    final loaded = store.loadEdits(s.id, 4800, clamp: true);
    expect(loaded.clips, [const Clip(0, 1000), const Clip(3000, 4800)]);
    expect(store.stackEdited(s), isTrue);
    store.deleteStack(s);
    expect(store.stackEdited(s), isFalse);
    expect(File(mixPath).existsSync(), isFalse);
  });

  test('sound start: skips leading silence and quiet noise', () {
    // 1 s of quiet room noise, then a clap at 1.0 s, 2 s in all.
    final mm = Float32List(375 * 2); // 375 blocks of 256 frames
    for (var b = 0; b < 375; b++) {
      final v = b < 187 ? 0.02 : (b == 187 ? 0.9 : 0.3);
      mm[2 * b] = -v;
      mm[2 * b + 1] = v;
    }
    final start = soundStartFrame(Peaks(mm, 256), 96000);
    expect(start, closeTo(48000, 256));
    expect(
      soundStartFrame(Peaks(Float32List(20), 256), 2560),
      0,
      reason: 'silence: no sound start, use the file start',
    );
  });
}
