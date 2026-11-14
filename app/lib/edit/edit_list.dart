// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Edit model (wiki/components/edit-model.md, wiki/decisions/d012-chop-model.md):
// a take is an immutable list of clips over its one recording. Every edit
// returns a new list, so undo is just keeping the old ones. Positions given to
// the operations are *timeline* frames (what the user sees); clips hold
// *recording* frames. Nothing here touches audio files.

import 'dart:convert';
import 'dart:math' as math;

import 'package:pocket_audio/pocket_audio.dart' show Fades, PlayClip;

import '../tempo/grid.dart';

export 'package:pocket_audio/pocket_audio.dart' show Fades;

class Clip {
  const Clip(
    this.start,
    this.end, {
    this.gain = 1.0,
    this.reverse = false,
    this.fades = Fades.none,
  }) : assert(end > start);

  /// Recording frames, end exclusive.
  final int start;
  final int end;
  final double gain;

  /// Played backwards (M7 reverse).
  final bool reverse;

  /// Fade in / fade out (M7), in the clip's own frames in timeline order
  /// (see [Fades]).
  final Fades fades;

  int get length => end - start;
  bool get hasFade => fades.any;

  /// Gain × fades [k] frames into the clip (as the engine plays it).
  double gainAt(num k) {
    var g = gain;
    final x = k + 0.5;
    if (fades.hasIn) g *= fadeCurve((x - fades.inA) / (fades.inB - fades.inA));
    if (fades.hasOut) {
      g *= fadeCurve((fades.outB - x) / (fades.outB - fades.outA));
    }
    return g;
  }

  /// Length of the fade in that starts at the clip's start (0 if none).
  int get fadeInFrames =>
      fades.hasIn && fades.inA <= 0 ? fades.inB.round().clamp(0, length) : 0;

  /// Length of the fade out that ends at the clip's end (0 if none).
  int get fadeOutFrames => fades.hasOut && fades.outB >= length
      ? (length - fades.outA.round()).clamp(0, length)
      : 0;

  /// Fade in over the first [frames] (0 = none), keeping the fade out.
  Clip withFadeIn(int frames) => _copy(
    fades: Fades(
      inB: frames.clamp(0, length).toDouble(),
      outA: fades.outA,
      outB: fades.outB,
    ),
  );

  /// Fade out over the last [frames] (0 = none), keeping the fade in.
  Clip withFadeOut(int frames) {
    final f = frames.clamp(0, length);
    return _copy(
      fades: Fades(
        inA: fades.inA,
        inB: fades.inB,
        outA: f == 0 ? 0 : (length - f).toDouble(),
        outB: f == 0 ? 0 : length.toDouble(),
      ),
    );
  }

  /// Recording frame at the boundary [k] frames into the clip (where a cut
  /// there would fall in the recording).
  int boundaryAt(int k) => reverse ? end - k : start + k;

  /// Recording frame heard [k] frames into the clip.
  int sourceAt(int k) => reverse ? end - 1 - k : start + k;

  /// The clip cut [k] frames in (0 < k < length), in timeline order. Each
  /// piece keeps its share of the fades, so a split never changes the sound.
  (Clip, Clip) splitAt(int k) {
    final b = boundaryAt(k);
    final later = fades.shift(k);
    return reverse
        ? (_copy(start: b, end: end), _copy(start: start, end: b, fades: later))
        : (
            _copy(start: start, end: b),
            _copy(start: b, end: end, fades: later),
          );
  }

  Clip _copy({
    int? start,
    int? end,
    double? gain,
    bool? reverse,
    Fades? fades,
  }) => Clip(
    start ?? this.start,
    end ?? this.end,
    gain: gain ?? this.gain,
    reverse: reverse ?? this.reverse,
    fades: fades ?? this.fades,
  );

  /// Same clip with other recording bounds (e.g. clamped to a shorter mix).
  Clip copyWith({int? start, int? end}) => _copy(start: start, end: end);

  /// Played backwards, with its fades mirrored to match (a fade in at the
  /// start becomes a fade out at the end).
  Clip reversed() {
    final n = length.toDouble();
    return _copy(
      reverse: !reverse,
      fades: Fades(
        inA: fades.hasOut ? n - fades.outB : 0,
        inB: fades.hasOut ? n - fades.outA : 0,
        outA: fades.hasIn ? n - fades.inB : 0,
        outB: fades.hasIn ? n - fades.inA : 0,
      ),
    );
  }

  Clip withoutFades() => _copy(fades: Fades.none);

  Clip withGain(double g) => _copy(gain: g);

  /// For the engine, with frames mapped by [map] (e.g. into a render whose
  /// frames are [scale] × the recording's).
  PlayClip toPlay([int Function(int)? map, double scale = 1]) => PlayClip(
    map == null ? start : map(start),
    map == null ? end : map(end),
    gain: gain,
    reverse: reverse,
    fades: scale == 1
        ? fades
        : Fades(
            inA: fades.inA * scale,
            inB: fades.inB * scale,
            outA: fades.outA * scale,
            outB: fades.outB * scale,
          ),
  );

  Map<String, Object> toJson() => {
    'start': start,
    'end': end,
    'gain': gain,
    if (reverse) 'reverse': true,
    if (fades.any) 'fades': [fades.inA, fades.inB, fades.outA, fades.outB],
  };

  static Clip fromJson(Map<String, dynamic> j) {
    final start = j['start'] as int, end = j['end'] as int;
    var fades = Fades.none;
    final f = j['fades'] as List?;
    if (f != null && f.length == 4) {
      final v = [for (final x in f) (x as num).toDouble()];
      fades = Fades(inA: v[0], inB: v[1], outA: v[2], outB: v[3]);
    } else if (j['env'] case [final num e0, final num e1] when e0 != e1) {
      // First M7 build (2026-11-14): a linear envelope position e0 → e1
      // across the clip. The same curve as fade ramps: where it hits 0 and 1.
      final n = (end - start).toDouble(), d = (e1 - e0).toDouble();
      final at0 = -e0 / d * n, at1 = (1 - e0) / d * n;
      fades = d > 0 ? Fades(inA: at0, inB: at1) : Fades(outA: at1, outB: at0);
    }
    return Clip(
      start,
      end,
      gain: (j['gain'] as num?)?.toDouble() ?? 1.0,
      reverse: j['reverse'] as bool? ?? false,
      fades: fades,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Clip &&
      other.start == start &&
      other.end == end &&
      other.gain == gain &&
      other.reverse == reverse &&
      other.fades == fades;

  @override
  int get hashCode => Object.hash(start, end, gain, reverse, fades);

  @override
  String toString() =>
      'Clip($start–$end${gain == 1 ? '' : ' ×$gain'}'
      '${reverse ? ' rev' : ''}${hasFade ? ' $fades' : ''})';
}

/// The fade curve the engine uses (sin² of a quarter turn), for drawing.
double fadeCurve(double x) {
  final s = math.sin(x.clamp(0.0, 1.0) * math.pi / 2);
  return s * s;
}

/// Whole-take pitch/tempo (wiki/decisions/d013-transpose-tempo-design.md).
class Tune {
  const Tune({
    this.semitones = 0,
    this.tempo = 1,
    this.formant = false,
    this.varispeed = 0,
  });

  static const none = Tune();
  static const minSemitones = -24.0, maxSemitones = 24.0;
  static const minTempo = 0.75, maxTempo = 1.5;
  static const minVarispeed = -24.0, maxVarispeed = 24.0;

  /// Pitch shift; the fractional part is cents (0.01 = 1 cent).
  final double semitones;

  /// Speed factor: 1.25 = 25% faster, same pitch.
  final double tempo;

  /// Preserve formants (keeps a voice natural when transposed).
  final bool formant;

  /// Varispeed in semitones (M7, wiki/concepts/varispeed.md): tape-style,
  /// pitch and speed together; +12 = an octave up at twice the speed.
  final double varispeed;

  /// Varispeed as a speed factor.
  double get speed => math.pow(2, varispeed / 12).toDouble();

  /// Recording frames per played frame: tempo and varispeed together.
  double get timeRatio => tempo * speed;

  /// Whether audio needs rendering at all (formant alone changes nothing).
  bool get isIdentity => semitones == 0 && tempo == 1 && varispeed == 0;

  Tune copyWith({
    double? semitones,
    double? tempo,
    bool? formant,
    double? varispeed,
  }) => Tune(
    semitones: (semitones ?? this.semitones).clamp(minSemitones, maxSemitones),
    tempo: (tempo ?? this.tempo).clamp(minTempo, maxTempo),
    formant: formant ?? this.formant,
    varispeed: (varispeed ?? this.varispeed).clamp(minVarispeed, maxVarispeed),
  );

  Map<String, Object> toJson() => {
    'semitones': semitones,
    'tempo': tempo,
    'formant': formant,
    if (varispeed != 0) 'varispeed': varispeed,
  };

  static Tune fromJson(Map<String, dynamic>? j) => j == null
      ? none
      : Tune(
          semitones: (j['semitones'] as num?)?.toDouble() ?? 0,
          tempo: (j['tempo'] as num?)?.toDouble() ?? 1,
          formant: j['formant'] as bool? ?? false,
          varispeed: (j['varispeed'] as num?)?.toDouble() ?? 0,
        ).copyWith(); // clamp

  @override
  bool operator ==(Object other) =>
      other is Tune &&
      other.semitones == semitones &&
      other.tempo == tempo &&
      other.formant == formant &&
      other.varispeed == varispeed;

  @override
  int get hashCode => Object.hash(semitones, tempo, formant, varispeed);

  @override
  String toString() =>
      'Tune($semitones st, ×$tempo${formant ? ', formant' : ''}'
      '${varispeed != 0 ? ', vari $varispeed st' : ''})';
}

class EditList {
  EditList(List<Clip> clips, {this.tune = Tune.none, this.grid})
    : clips = List.unmodifiable(clips);

  /// The whole recording as one clip.
  factory EditList.whole(int recordingFrames) =>
      EditList([if (recordingFrames > 0) Clip(0, recordingFrames)]);

  final List<Clip> clips;

  /// Pitch/tempo for the whole take (M4).
  final Tune tune;

  /// Beat grid on the edit timeline (M5b, d017), or null. Not an edit:
  /// [isWhole] ignores it.
  final Grid? grid;

  /// Same clips, new pitch/tempo.
  EditList withTune(Tune next) => EditList(clips, tune: next, grid: grid);

  /// Same clips, another beat grid (null = none).
  EditList withGrid(Grid? next) => EditList(clips, tune: tune, grid: next);

  EditList _with(List<Clip> next) => EditList(next, tune: tune, grid: grid);

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
    return l.index < clips.length ? clips[l.index].sourceAt(l.offset) : null;
  }

  bool isWhole(int recordingFrames) =>
      clips.length == 1 &&
      clips.single == Clip(0, recordingFrames) &&
      tune == Tune.none;

  /// Cuts the clip under [t] in two (no-op at an existing boundary or end).
  EditList split(int t) {
    final l = locate(t);
    if (l.index >= clips.length || l.offset == 0) return this;
    final (a, b) = clips[l.index].splitAt(l.offset);
    return _with([
      ...clips.sublist(0, l.index),
      a,
      b,
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
    return _with([...cut.clips.sublist(0, first), ...cut.clips.sublist(last)]);
  }

  /// Keeps only timeline [a, b).
  EditList trim(int a, int b) {
    if (b <= a) return this;
    final (cut, first, last) = _isolate(a, b);
    return _with(cut.clips.sublist(first, last));
  }

  /// Inserts a copy of timeline [a, b) right after it.
  EditList duplicate(int a, int b) {
    if (b <= a) return this;
    final (cut, first, last) = _isolate(a, b);
    final copy = cut.clips.sublist(first, last);
    return _with([
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
    return _with(list);
  }

  // ---- sampling tools (M7, wiki/decisions/d016-sampling-tools.md) ----

  /// Plays timeline [a, b) backwards: its clips in reverse order, each one
  /// reversed. Doing it twice gives the original sound back.
  EditList reverse(int a, int b) {
    if (b <= a) return this;
    final (cut, first, last) = _isolate(a, b);
    return _with([
      ...cut.clips.sublist(0, first),
      for (final c in cut.clips.sublist(first, last).reversed) c.reversed(),
      ...cut.clips.sublist(last),
    ]);
  }

  /// Fades clip [index] in over its first [frames] (0 = no fade in).
  EditList setFadeIn(int index, int frames) => _with([
    for (var i = 0; i < clips.length; i++)
      i == index ? clips[i].withFadeIn(frames) : clips[i],
  ]);

  /// Fades clip [index] out over its last [frames] (0 = no fade out).
  EditList setFadeOut(int index, int frames) => _with([
    for (var i = 0; i < clips.length; i++)
      i == index ? clips[i].withFadeOut(frames) : clips[i],
  ]);

  /// Length of the fade in that starts at timeline [a] (the start of a
  /// region [a, b): the take or a selection), or 0.
  int regionFadeIn(int a, int b) {
    final l = locate(a);
    if (l.index >= clips.length || l.offset != 0) return 0;
    final f = clips[l.index].fades;
    if (!f.hasIn || f.inA.abs() > 0.5) return 0;
    return f.inB.round().clamp(0, b - a);
  }

  /// Length of the fade out that ends at timeline [b] (see [regionFadeIn]).
  int regionFadeOut(int a, int b) {
    if (b <= a) return 0;
    final l = locate(b - 1);
    if (l.index >= clips.length) return 0;
    final c = clips[l.index];
    if (l.offset != c.length - 1) return 0;
    final f = c.fades;
    if (!f.hasOut || (f.outB - c.length).abs() > 0.5) return 0;
    return (c.length - f.outA).round().clamp(0, b - a);
  }

  /// Fades region [a, b) in over its first [frames] (0 = none): one curve
  /// from [a], shared by every clip it crosses (each holds its part, in its
  /// own frames). Splits at [a] when a fade starts inside a clip, so the
  /// audio before it is untouched. Replaces the region's previous fade in.
  EditList fadeRegionIn(int a, int b, int frames) {
    if (b <= a) return this;
    frames = frames.clamp(0, b - a);
    final list = frames > 0 ? split(a) : this;
    final next = <Clip>[];
    var p = 0;
    for (final c in list.clips) {
      final f = c.fades;
      final inRegion = p >= a && p < b;
      final fromA = f.hasIn && (f.inA - (a - p)).abs() <= 0.5;
      if (inRegion && p < a + frames) {
        next.add(
          c._copy(
            fades: f.withIn((a - p).toDouble(), (a + frames - p).toDouble()),
          ),
        );
      } else if (inRegion && fromA) {
        next.add(c._copy(fades: f.withIn(0, 0))); // was part of the old fade
      } else {
        next.add(c);
      }
      p += c.length;
    }
    return _with(next);
  }

  /// Fades region [a, b) out over its last [frames] (see [fadeRegionIn]).
  EditList fadeRegionOut(int a, int b, int frames) {
    if (b <= a) return this;
    frames = frames.clamp(0, b - a);
    final list = frames > 0 ? split(b) : this;
    final next = <Clip>[];
    var p = 0;
    for (final c in list.clips) {
      final f = c.fades;
      final q = p + c.length;
      final inRegion = q > a && q <= b;
      final toB = f.hasOut && (f.outB - (b - p)).abs() <= 0.5;
      if (inRegion && q > b - frames) {
        next.add(
          c._copy(
            fades: f.withOut((b - frames - p).toDouble(), (b - p).toDouble()),
          ),
        );
      } else if (inRegion && toB) {
        next.add(c._copy(fades: f.withOut(0, 0)));
      } else {
        next.add(c);
      }
      p = q;
    }
    return _with(next);
  }

  /// Removes fades in timeline [a, b) (whole clips that overlap it).
  EditList clearFades(int a, int b) {
    final l0 = locate(a).index, l1 = locate(math.max(a, b - 1)).index;
    return _with([
      for (var i = 0; i < clips.length; i++)
        i >= l0 && i <= l1 ? clips[i].withoutFades() : clips[i],
    ]);
  }

  /// Whether any clip overlapping timeline [a, b) has a fade.
  bool hasFadeOver(int a, int b) {
    final l0 = locate(a).index, l1 = locate(math.max(a, b - 1)).index;
    for (var i = l0; i <= l1 && i < clips.length; i++) {
      if (clips[i].hasFade) return true;
    }
    return false;
  }

  /// Multiplies the gain of timeline [a, b) by [factor] (normalize).
  EditList scaleGain(int a, int b, double factor) {
    if (b <= a || factor == 1) return this;
    final (cut, first, last) = _isolate(a, b);
    return _with([
      ...cut.clips.sublist(0, first),
      for (final c in cut.clips.sublist(first, last))
        c.withGain(c.gain * factor),
      ...cut.clips.sublist(last),
    ]);
  }

  /// `grid` (M5b) is optional and needs no version bump: older readers
  /// ignore it.
  /// Version 3 adds per-clip `reverse`/`fades` and `tune.varispeed` (M7);
  /// version 2 added `tune`; version 1 files (M3) load with no transpose.
  String toJsonString() => jsonEncode({
    'version': 3,
    'clips': [for (final c in clips) c.toJson()],
    if (tune != Tune.none) 'tune': tune.toJson(),
    if (grid != null) 'grid': grid!.toJson(),
  });

  static EditList fromJsonString(String s) {
    final j = jsonDecode(s) as Map<String, dynamic>;
    return EditList(
      [
        for (final c in j['clips'] as List)
          Clip.fromJson(c as Map<String, dynamic>),
      ],
      tune: Tune.fromJson(j['tune'] as Map<String, dynamic>?),
      grid: Grid.fromJson(j['grid'] as Map<String, dynamic>?),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is EditList &&
      other.tune == tune &&
      other.grid == grid &&
      other.clips.length == clips.length &&
      Iterable.generate(clips.length).every((i) => other.clips[i] == clips[i]);

  @override
  int get hashCode => Object.hash(tune, grid, Object.hashAll(clips));
}

/// Unlimited undo/redo over immutable snapshots (d012): clip lists, stacks.
/// [T] must have value equality. Session only; the
/// history is persisted with projects in M8 (wiki/features/undo-history.md).
class History<T> {
  History(T initial) : _states = [(label: '', list: initial)];

  final List<({String label, T list})> _states;
  int _index = 0;

  T get current => _states[_index].list;
  bool get canUndo => _index > 0;
  bool get canRedo => _index < _states.length - 1;
  String? get undoLabel => canUndo ? _states[_index].label : null;
  String? get redoLabel => canRedo ? _states[_index + 1].label : null;

  /// Records [next] as a new state. Ignored if nothing changed. Clears redo.
  /// With [coalesce], a run of edits with the same label (e.g. tapping the
  /// pitch button five times) becomes a single undo step.
  bool push(String label, T next, {bool coalesce = false}) {
    if (next == current) return false;
    _states.removeRange(_index + 1, _states.length);
    if (coalesce && _index > 0 && _states[_index].label == label) {
      _states[_index] = (label: label, list: next);
      // Coalescing back to the previous state undoes the step entirely.
      if (_states[_index - 1].list == next) {
        _states.removeAt(_index);
        _index--;
      }
      return true;
    }
    _states.add((label: label, list: next));
    _index++;
    return true;
  }

  T undo() {
    if (canUndo) _index--;
    return current;
  }

  T redo() {
    if (canRedo) _index++;
    return current;
  }
}

/// The take editor's history (clip lists).
typedef EditHistory = History<EditList>;

extension on Fades {
  /// The same fades with another fade-in ramp (0, 0 = none).
  Fades withIn(double a, double b) =>
      Fades(inA: a, inB: b, outA: outA, outB: outB);

  /// The same fades with another fade-out ramp (0, 0 = none).
  Fades withOut(double a, double b) =>
      Fades(inA: inA, inB: inB, outA: a, outB: b);
}
