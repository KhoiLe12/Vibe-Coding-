// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Tempo everywhere (M5b, wiki/features/beat-grid.md, wiki/decisions/
// d017-tempo-everywhere.md): one beat grid for takes, stacks and loops —
// BPM, time signature and where the first downbeat is. Positions are frames
// at 48 kHz on whatever timeline the grid belongs to (a take's edit
// timeline, a stack's timeline).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

const _rate = 48000;

class Grid {
  const Grid({
    required this.bpm,
    this.beatsPerBar = 4,
    this.beatUnit = 4,
    this.downbeat = 0,
  });

  static const minBpm = 30.0, maxBpm = 300.0;

  /// Beats per minute, counting [beatUnit] notes (quarters for /4).
  final double bpm;
  final int beatsPerBar;

  /// 4 or 8: the note that gets the beat.
  final int beatUnit;

  /// Frame of a bar's first beat (any bar; the grid runs both ways).
  final double downbeat;

  double get beatFrames => _rate * 60 / bpm;
  double get barFrames => beatFrames * beatsPerBar;

  Grid copyWith({
    double? bpm,
    int? beatsPerBar,
    int? beatUnit,
    double? downbeat,
  }) => Grid(
    bpm: bpm ?? this.bpm,
    beatsPerBar: beatsPerBar ?? this.beatsPerBar,
    beatUnit: beatUnit ?? this.beatUnit,
    downbeat: downbeat ?? this.downbeat,
  );

  /// The same grid seen through a time ratio (recording frames per displayed
  /// frame): played faster, the beats are closer and the BPM higher.
  Grid scaled(double ratio) => ratio == 1
      ? this
      : copyWith(bpm: bpm * ratio, downbeat: downbeat / ratio);

  /// Beat index at frame [t] (fractional; 0 at [downbeat]).
  double beatAt(num t) => (t - downbeat) / beatFrames;

  /// Frame of beat [i] (0 = [downbeat]).
  double frameOfBeat(num i) => downbeat + i * beatFrames;

  /// Nearest beat to [t], in frames.
  int nearestBeat(num t) => frameOfBeat(beatAt(t).roundToDouble()).round();

  /// Whether beat [i] starts a bar.
  bool isBar(int i) => i % beatsPerBar == 0;

  /// Beat lines in [from, to): frame and whether it starts a bar. Beats
  /// are left out when there'd be more than [maxLines] (bars only), and
  /// bars thinned the same way.
  List<({double frame, bool bar})> lines(
    double from,
    double to, {
    int maxLines = 200,
  }) {
    if (to <= from) return const [];
    final beats = (to - from) / beatFrames;
    var step = 1; // in beats
    if (beats > maxLines) {
      step = beatsPerBar;
      while ((to - from) / (beatFrames * step) > maxLines) {
        step *= 2;
      }
    }
    final first = (beatAt(from) / step).ceil() * step;
    final out = <({double frame, bool bar})>[];
    for (var i = first; ; i += step) {
      final f = frameOfBeat(i);
      if (f >= to) break;
      out.add((frame: f, bar: isBar(i)));
    }
    return out;
  }

  String get signature => '$beatsPerBar/$beatUnit';
  String get bpmLabel => bpm == bpm.roundToDouble()
      ? bpm.round().toString()
      : bpm.toStringAsFixed(1);
  String get label => '$bpmLabel BPM · $signature';

  Map<String, Object> toJson() => {
    'bpm': bpm,
    'beatsPerBar': beatsPerBar,
    'beatUnit': beatUnit,
    'downbeat': downbeat,
  };

  static Grid? fromJson(Map<String, dynamic>? j) {
    final bpm = (j?['bpm'] as num?)?.toDouble();
    if (j == null || bpm == null || bpm <= 0) return null;
    return Grid(
      bpm: bpm,
      beatsPerBar: j['beatsPerBar'] as int? ?? 4,
      beatUnit: j['beatUnit'] as int? ?? 4,
      downbeat: (j['downbeat'] as num?)?.toDouble() ?? 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Grid &&
      other.bpm == bpm &&
      other.beatsPerBar == beatsPerBar &&
      other.beatUnit == beatUnit &&
      other.downbeat == downbeat;

  @override
  int get hashCode => Object.hash(bpm, beatsPerBar, beatUnit, downbeat);

  @override
  String toString() => 'Grid($label @ $downbeat)';
}

/// Tap tempo: the average of the last few intervals; a pause over 2 s
/// starts again.
class TapTempo {
  final _taps = <int>[]; // microseconds

  /// Records a tap at [micros] (defaults to now); returns the BPM once there
  /// are two taps.
  double? tap([int? micros]) {
    final t = micros ?? DateTime.now().microsecondsSinceEpoch;
    if (_taps.isNotEmpty && t - _taps.last > 2000000) _taps.clear();
    _taps.add(t);
    if (_taps.length > 8) _taps.removeAt(0);
    if (_taps.length < 2) return null;
    final span = (_taps.last - _taps.first) / (_taps.length - 1);
    final bpm = 60e6 / span;
    return bpm.clamp(Grid.minBpm, Grid.maxBpm).toDouble();
  }

  int get count => _taps.length;
  void reset() => _taps.clear();
}

/// The tempo last used, the default for the next recording, loop or stack;
/// plus the count-in and click settings. Saved in one small JSON file.
class TempoSettings {
  const TempoSettings({
    this.bpm = 120,
    this.beatsPerBar = 4,
    this.beatUnit = 4,
    this.countInBars = 1,
    this.clickWhileRecording = false,
    this.recordWithTempo = false,
  });

  final double bpm;
  final int beatsPerBar, beatUnit;

  /// 0, 1 or 2.
  final int countInBars;

  /// Keep clicking while recording (headphones; the speaker would be
  /// recorded).
  final bool clickWhileRecording;

  /// The Record screen's tempo toggle.
  final bool recordWithTempo;

  Grid grid({double downbeat = 0}) => Grid(
    bpm: bpm,
    beatsPerBar: beatsPerBar,
    beatUnit: beatUnit,
    downbeat: downbeat,
  );

  int get countInBeats => countInBars * beatsPerBar;

  TempoSettings copyWith({
    double? bpm,
    int? beatsPerBar,
    int? beatUnit,
    int? countInBars,
    bool? clickWhileRecording,
    bool? recordWithTempo,
  }) => TempoSettings(
    bpm: bpm ?? this.bpm,
    beatsPerBar: beatsPerBar ?? this.beatsPerBar,
    beatUnit: beatUnit ?? this.beatUnit,
    countInBars: countInBars ?? this.countInBars,
    clickWhileRecording: clickWhileRecording ?? this.clickWhileRecording,
    recordWithTempo: recordWithTempo ?? this.recordWithTempo,
  );

  TempoSettings withGrid(Grid g) =>
      copyWith(bpm: g.bpm, beatsPerBar: g.beatsPerBar, beatUnit: g.beatUnit);

  static TempoSettings load(File f) {
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return TempoSettings(
        bpm: ((j['bpm'] as num?)?.toDouble() ?? 120)
            .clamp(Grid.minBpm, Grid.maxBpm)
            .toDouble(),
        beatsPerBar: j['beatsPerBar'] as int? ?? 4,
        beatUnit: j['beatUnit'] as int? ?? 4,
        countInBars: math.min(2, math.max(0, j['countInBars'] as int? ?? 1)),
        clickWhileRecording: j['clickWhileRecording'] as bool? ?? false,
        recordWithTempo: j['recordWithTempo'] as bool? ?? false,
      );
    } on Object {
      return const TempoSettings();
    }
  }

  void save(File f) {
    try {
      File('${f.path}.tmp')
        ..writeAsStringSync(
          jsonEncode({
            'bpm': bpm,
            'beatsPerBar': beatsPerBar,
            'beatUnit': beatUnit,
            'countInBars': countInBars,
            'clickWhileRecording': clickWhileRecording,
            'recordWithTempo': recordWithTempo,
          }),
        )
        ..renameSync(f.path);
    } on Object {
      // A preference; losing it is harmless.
    }
  }
}

/// A detected tempo (M5b): the grid and how sure the detector was (0..1).
typedef DetectedTempo = ({Grid grid, double confidence});
