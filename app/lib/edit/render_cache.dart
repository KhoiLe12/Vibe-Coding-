// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Transposed / time-stretched renders of a take's recording
// (wiki/decisions/d013-transpose-tempo-design.md, wiki/components/storage.md).
// A render covers a range of the recording at one Tune; clips that fall
// inside that range play from it, so chopping needs no re-render. Files:
//   renders/<take>__<cents>_<tempo‰>_<f>_<start>_<end>.wav
// (double underscore: take ids may themselves end in "_2")
// The folder is a disposable cache with a size cap.

import 'dart:io';
import 'dart:math' as math;

import 'edit_list.dart';

/// Extra recording rendered around the used range, so join crossfades and
/// small edits near the ends still fall inside the render.
const renderMarginFrames = 24000; // 0.5 s

/// Total size the cache may use before the oldest renders are deleted.
const renderCacheMaxBytes = 1024 * 1024 * 1024; // 1 GiB

class Render {
  const Render(this.path, this.start, this.end, this.tune);

  final String path;

  /// Range of the recording it covers (recording frames, end exclusive).
  final int start, end;
  final Tune tune;

  bool covers(int a, int b) => start <= a && b <= end;

  /// Clips mapped from recording frames into this render's frames.
  List<({int start, int end, double gain})> clipsFor(EditList e) => [
    for (final c in e.clips)
      (
        start: ((c.start - start) / tune.tempo).round(),
        end: ((c.end - start) / tune.tempo).round(),
        gain: c.gain,
      ),
  ];
}

class RenderCache {
  RenderCache(this.dir) {
    dir.createSync(recursive: true);
  }

  final Directory dir;

  /// Range of the recording the edit list uses, plus the margin.
  static ({int start, int end}) neededRange(EditList e, int recordingFrames) {
    var a = recordingFrames, b = 0;
    for (final c in e.clips) {
      a = math.min(a, c.start);
      b = math.max(b, c.end);
    }
    if (b <= a) return (start: 0, end: 0);
    return (
      start: math.max(0, a - renderMarginFrames),
      end: math.min(recordingFrames, b + renderMarginFrames),
    );
  }

  static String _tuneKey(Tune t) =>
      '${(t.semitones * 100).round()}_${(t.tempo * 1000).round()}_'
      '${t.formant ? 1 : 0}';

  /// Where a render of [start, end) at [tune] lives.
  Render planFor(String takeId, Tune tune, int start, int end) => Render(
    '${dir.path}/${takeId}__${_tuneKey(tune)}_${start}_$end.wav',
    start,
    end,
    tune,
  );

  /// A finished render of the take at [tune] covering [start, end), if any.
  Render? find(String takeId, Tune tune, int start, int end) {
    final prefix = '${takeId}__${_tuneKey(tune)}_';
    for (final f in _files()) {
      final name = f.uri.pathSegments.last;
      if (!name.startsWith(prefix) || !name.endsWith('.wav')) continue;
      final parts = name.substring(prefix.length, name.length - 4).split('_');
      if (parts.length != 2) continue;
      final s = int.tryParse(parts[0]), e = int.tryParse(parts[1]);
      if (s == null || e == null) continue;
      final r = Render(f.path, s, e, tune);
      if (r.covers(start, end)) {
        f.setLastModifiedSync(DateTime.now()); // recently used
        return r;
      }
    }
    return null;
  }

  /// Deletes every render of a take (e.g. when the take is deleted).
  void deleteFor(String takeId) {
    for (final f in _files()) {
      if (f.uri.pathSegments.last.startsWith('${takeId}__')) f.deleteSync();
    }
  }

  /// Deletes least recently used renders until the cache fits the cap.
  void trim({int maxBytes = renderCacheMaxBytes, Set<String> keep = const {}}) {
    final files = _files().toList()
      ..sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
    var total = files.fold<int>(0, (s, f) => s + f.lengthSync());
    for (final f in files) {
      if (total <= maxBytes) break;
      if (keep.contains(f.path)) continue;
      total -= f.lengthSync();
      f.deleteSync();
    }
  }

  Iterable<File> _files() =>
      dir.listSync().whereType<File>().where((f) => f.path.endsWith('.wav'));
}
