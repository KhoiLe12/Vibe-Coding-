// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Edit model (wiki/components/edit-model.md, wiki/decisions/d012-chop-model.md):
// a take is an immutable list of clips over its one recording. Every edit
// returns a new list, so undo is just keeping the old ones. Positions given to
// the operations are *timeline* frames (what the user sees); clips hold
// *recording* frames. Nothing here touches audio files.

import 'dart:convert';

class Clip {
  const Clip(this.start, this.end, {this.gain = 1.0}) : assert(end > start);

  /// Recording frames, end exclusive.
  final int start;
  final int end;
  final double gain;

  int get length => end - start;

  Clip copyWith({int? start, int? end}) =>
      Clip(start ?? this.start, end ?? this.end, gain: gain);

  Map<String, Object> toJson() => {'start': start, 'end': end, 'gain': gain};

  static Clip fromJson(Map<String, dynamic> j) => Clip(
    j['start'] as int,
    j['end'] as int,
    gain: (j['gain'] as num?)?.toDouble() ?? 1.0,
  );

  @override
  bool operator ==(Object other) =>
      other is Clip &&
      other.start == start &&
      other.end == end &&
      other.gain == gain;

  @override
  int get hashCode => Object.hash(start, end, gain);

  @override
  String toString() => 'Clip($start–$end${gain == 1 ? '' : ' ×$gain'})';
}

class EditList {
  EditList(List<Clip> clips) : clips = List.unmodifiable(clips);

  /// The whole recording as one clip.
  factory EditList.whole(int recordingFrames) =>
      EditList([if (recordingFrames > 0) Clip(0, recordingFrames)]);

  final List<Clip> clips;

  int get length => clips.fold(0, (sum, c) => sum + c.length);

  /// Timeline frame where clip [index] starts.
  int startOf(int index) {
    var t = 0;
    for (var i = 0; i < index; i++) {
      t += clips[i].length;
    }
    return t;
  }

  /// Clip index and offset into it for timeline frame [t] (clamped).
  ({int index, int offset}) locate(int t) {
    var acc = 0;
    for (var i = 0; i < clips.length; i++) {
      if (t < acc + clips[i].length) return (index: i, offset: t - acc);
      acc += clips[i].length;
    }
    return (index: clips.length, offset: 0); // at or past the end
  }

  /// Recording frame under timeline frame [t], or null past the end.
  int? sourceAt(int t) {
    final l = locate(t);
    return l.index < clips.length ? clips[l.index].start + l.offset : null;
  }

  bool isWhole(int recordingFrames) =>
      clips.length == 1 &&
      clips.single.start == 0 &&
      clips.single.end == recordingFrames &&
      clips.single.gain == 1.0;

  /// Cuts the clip under [t] in two (no-op at an existing boundary or end).
  EditList split(int t) {
    final l = locate(t);
    if (l.index >= clips.length || l.offset == 0) return this;
    final c = clips[l.index];
    return EditList([
      ...clips.sublist(0, l.index),
      c.copyWith(end: c.start + l.offset),
      c.copyWith(start: c.start + l.offset),
      ...clips.sublist(l.index + 1),
    ]);
  }

  /// Index range of clips covering timeline [a, b) after splitting there.
  (EditList, int, int) _isolate(int a, int b) {
    final cut = split(a).split(b);
    final first = cut.locate(a).index;
    final last = cut.locate(b).index; // exclusive
    return (cut, first, last);
  }

  /// Removes timeline [a, b).
  EditList delete(int a, int b) {
    if (b <= a) return this;
    final (cut, first, last) = _isolate(a, b);
    return EditList([
      ...cut.clips.sublist(0, first),
      ...cut.clips.sublist(last),
    ]);
  }

  /// Keeps only timeline [a, b).
  EditList trim(int a, int b) {
    if (b <= a) return this;
    final (cut, first, last) = _isolate(a, b);
    return EditList(cut.clips.sublist(first, last));
  }

  /// Inserts a copy of timeline [a, b) right after it.
  EditList duplicate(int a, int b) {
    if (b <= a) return this;
    final (cut, first, last) = _isolate(a, b);
    final copy = cut.clips.sublist(first, last);
    return EditList([
      ...cut.clips.sublist(0, last),
      ...copy,
      ...cut.clips.sublist(last),
    ]);
  }

  /// Moves clip [from] so it ends up at index [to] (in the new list).
  EditList move(int from, int to) {
    if (from == to || from < 0 || from >= clips.length) return this;
    final list = [...clips];
    final c = list.removeAt(from);
    list.insert(to.clamp(0, list.length), c);
    return EditList(list);
  }

  String toJsonString() => jsonEncode({
    'version': 1,
    'clips': [for (final c in clips) c.toJson()],
  });

  static EditList fromJsonString(String s) {
    final j = jsonDecode(s) as Map<String, dynamic>;
    return EditList([
      for (final c in j['clips'] as List)
        Clip.fromJson(c as Map<String, dynamic>),
    ]);
  }

  @override
  bool operator ==(Object other) =>
      other is EditList &&
      other.clips.length == clips.length &&
      Iterable.generate(clips.length).every((i) => other.clips[i] == clips[i]);

  @override
  int get hashCode => Object.hashAll(clips);
}

/// Unlimited undo/redo over immutable snapshots (d012). Session only; the
/// history is persisted with projects in M7 (wiki/features/undo-history.md).
class EditHistory {
  EditHistory(EditList initial) : _states = [(label: '', list: initial)];

  final List<({String label, EditList list})> _states;
  int _index = 0;

  EditList get current => _states[_index].list;
  bool get canUndo => _index > 0;
  bool get canRedo => _index < _states.length - 1;
  String? get undoLabel => canUndo ? _states[_index].label : null;
  String? get redoLabel => canRedo ? _states[_index + 1].label : null;

  /// Records [next] as a new state. Ignored if nothing changed. Clears redo.
  bool push(String label, EditList next) {
    if (next == current) return false;
    _states.removeRange(_index + 1, _states.length);
    _states.add((label: label, list: next));
    _index++;
    return true;
  }

  EditList undo() {
    if (canUndo) _index--;
    return current;
  }

  EditList redo() {
    if (canRedo) _index++;
    return current;
  }
}
