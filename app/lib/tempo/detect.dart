// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Tempo detection for a take (M5b, wiki/features/beat-grid.md): analyses the
// recording through the take's clips (edit timeline; pitch/tempo don't
// matter), in a background isolate.

import 'dart:isolate';

import 'package:pocket_audio/pocket_audio.dart';

import '../edit/edit_list.dart';
import 'grid.dart';

/// Detects the tempo of edit frames [a, b) of [edits] over the recording at
/// [source] (default: the whole take). The grid's downbeat is in edit
/// frames. Null if no beat was found.
Future<DetectedTempo?> detectTakeTempo({
  required String source,
  required EditList edits,
  int? a,
  int? b,
  int beatsPerBar = 4,
  int beatUnit = 4,
}) async {
  final from = a ?? 0, to = b ?? edits.length;
  if (to <= from) return null;
  final clips = [for (final c in edits.trim(from, to).clips) c.toPlay()];
  final r = await Isolate.run(
    () => PocketAudio.detectTempo(
      source: source,
      clips: clips,
      beatsPerBar: beatsPerBar,
    ),
  );
  if (r == null) return null;
  return (
    grid: Grid(
      bpm: (r.bpm * 100).round() / 100,
      beatsPerBar: beatsPerBar,
      beatUnit: beatUnit,
      downbeat: from + r.firstBeat,
    ),
    confidence: r.confidence,
  );
}
