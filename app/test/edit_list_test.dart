// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_studio/edit/edit_list.dart';

void main() {
  final whole = EditList.whole(1000);

  test('split cuts the clip under the position; boundaries are no-ops', () {
    final s = whole.split(300);
    expect(s.clips, [const Clip(0, 300), const Clip(300, 1000)]);
    expect(s.length, 1000);
    expect(s.split(300), s, reason: 'already a boundary');
    expect(s.split(0), s);
    expect(s.split(1000), s);
  });

  test('delete removes a timeline range across clips', () {
    final e = whole.split(500).delete(400, 600);
    expect(e.clips, [const Clip(0, 400), const Clip(600, 1000)]);
    expect(e.length, 800);
  });

  test('trim keeps only the range', () {
    expect(whole.trim(100, 250).clips, [const Clip(100, 250)]);
  });

  test('duplicate inserts a copy right after the range', () {
    final d = whole.duplicate(100, 200);
    expect(d.clips, [
      const Clip(0, 100),
      const Clip(100, 200),
      const Clip(100, 200),
      const Clip(200, 1000),
    ]);
    expect(d.length, 1100);
  });

  test('timeline positions follow earlier edits', () {
    // After deleting [100, 200), timeline 150 is recording 250.
    final e = whole.delete(100, 200);
    expect(e.sourceAt(150), 250);
    expect(e.sourceAt(e.length), isNull);
  });

  test('move reorders clips', () {
    final s = whole.split(300).split(600); // A B C
    final m = s.move(2, 0); // C A B
    expect(m.clips, [
      const Clip(600, 1000),
      const Clip(0, 300),
      const Clip(300, 600),
    ]);
    expect(m.move(0, 2).clips, [
      const Clip(0, 300),
      const Clip(300, 600),
      const Clip(600, 1000),
    ]);
  });

  test('JSON round trip', () {
    final e = whole.split(10).duplicate(0, 10);
    expect(EditList.fromJsonString(e.toJsonString()), e);
  });

  test('isWhole recognises an unedited take', () {
    expect(whole.isWhole(1000), isTrue);
    expect(whole.split(5).isWhole(1000), isFalse);
  });

  group('history', () {
    test('every edit undoes and redoes; new edits clear redo', () {
      final h = EditHistory(whole);
      h.push('Split', h.current.split(500));
      h.push('Delete', h.current.delete(0, 100));
      expect(h.current.length, 900);
      expect(h.undoLabel, 'Delete');
      expect(h.undo().length, 1000);
      expect(h.undo(), whole);
      expect(h.canUndo, isFalse);
      expect(h.redo().clips.length, 2);
      expect(h.redoLabel, 'Delete');
      h.push('Trim', h.current.trim(0, 10));
      expect(h.canRedo, isFalse);
      expect(h.current.length, 10);
    });

    test('no-op edits are not recorded', () {
      final h = EditHistory(whole);
      expect(h.push('Split', whole.split(0)), isFalse);
      expect(h.canUndo, isFalse);
    });
  });

  group('tune (M4)', () {
    test('edits keep the tune; tune is part of equality and JSON', () {
      final tuned = whole.withTune(const Tune(semitones: 3.25, tempo: 1.2));
      expect(tuned.split(10).delete(0, 5).tune, tuned.tune);
      expect(tuned == whole, isFalse);
      expect(tuned.isWhole(1000), isFalse);
      expect(EditList.fromJsonString(tuned.toJsonString()), tuned);
    });

    test('version-1 files (M3) load with no transpose', () {
      const v1 = '{"version":1,"clips":[{"start":0,"end":500,"gain":1.0}]}';
      expect(EditList.fromJsonString(v1).tune, Tune.none);
    });

    test('values are clamped to the allowed ranges', () {
      final t = Tune.none.copyWith(semitones: 30, tempo: 2);
      expect(t.semitones, 24);
      expect(t.tempo, 1.5);
      expect(Tune.none.copyWith(tempo: 0.5).tempo, 0.75);
    });

    test('repeated pitch taps coalesce into one undo step', () {
      final h = EditHistory(whole);
      for (var st = 1; st <= 5; st++) {
        h.push(
          'Pitch',
          h.current.withTune(Tune(semitones: st.toDouble())),
          coalesce: true,
        );
      }
      expect(h.current.tune.semitones, 5);
      expect(h.undo(), whole);
      expect(h.canUndo, isFalse);
      // Tapping back to the start removes the step.
      h.redo();
      h.push('Pitch', h.current.withTune(Tune.none), coalesce: true);
      expect(h.canUndo, isFalse);
    });
  });
}
