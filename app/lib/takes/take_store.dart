// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Takes on disk (wiki/components/storage.md). M1 keeps every take in one
// project folder, "inbox":
//   <documents>/projects/inbox/sources/<id>.wav   immutable recordings
//   <documents>/projects/inbox/peaks/<id>.bin     waveform caches (rebuildable)
//   <documents>/projects/inbox/renders/<id>_*.wav transposed/stretched renders
//                                                  (disposable cache, M4)
//   <documents>/projects/inbox/edits/<id>.json    edit list (absent = unedited;
//                                                  wiki/decisions/d012-chop-model.md)

import 'dart:io';
import 'dart:math' as math;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pocket_audio/pocket_audio.dart';

import '../edit/edit_list.dart';
import '../edit/render_cache.dart';
import '../stack/stack.dart';

/// Header size of the WAVs our recorder writes (RIFF + fmt + fact + data).
const _wavHeaderBytes = 58;
const sampleRate = 48000;

class Take {
  Take(
    this.id,
    this.wav,
    this.peaks,
    this.created,
    this.frames, {
    this.editedFrames,
    String? editsId,
  }) : editsId = editsId ?? id;

  /// Key of the saved edits. Same as [id] for a take; for a stack's
  /// combined mix it is the stack id, so the stack's edits survive the mix
  /// being re-made when layers change (M6).
  final String editsId;

  bool get isStackMix => editsId != id;

  final String id;
  final File wav;
  final File peaks;
  final DateTime created;

  /// Length of the recording itself.
  final int frames;

  /// Length after edits, or null if the take is unedited.
  final int? editedFrames;

  bool get edited => editedFrames != null;

  /// What the user hears: the edited length if edited.
  Duration get duration =>
      Duration(microseconds: (editedFrames ?? frames) * 1000000 ~/ sampleRate);
}

/// Min/max pairs, one per [blockFrames] frames.
class Peaks {
  Peaks(this.minMax, this.blockFrames);

  final Float32List minMax;
  final int blockFrames;

  int get blocks => minMax.length ~/ 2;

  static Peaks? parse(Uint8List bytes) {
    if (bytes.length < 16 ||
        String.fromCharCodes(bytes.sublist(0, 4)) != 'PSPK') {
      return null;
    }
    final h = ByteData.sublistView(bytes);
    final block = h.getUint32(8, Endian.little);
    final count = h.getUint32(12, Endian.little);
    if (bytes.length < 16 + count * 8) return null;
    // Copy so the floats are 4-byte aligned.
    final data = Uint8List.fromList(bytes.sublist(16, 16 + count * 8));
    return Peaks(Float32List.view(data.buffer), block);
  }
}

class TakeStore {
  TakeStore(Directory projectDir)
    : sources = Directory('${projectDir.path}/sources'),
      peaksDir = Directory('${projectDir.path}/peaks'),
      editsDir = Directory('${projectDir.path}/edits'),
      stacksDir = Directory('${projectDir.path}/stacks'),
      renders = RenderCache(Directory('${projectDir.path}/renders')) {
    sources.createSync(recursive: true);
    peaksDir.createSync(recursive: true);
    editsDir.createSync(recursive: true);
    stacksDir.createSync(recursive: true);
  }

  final Directory sources;
  final Directory peaksDir;
  final Directory editsDir;

  /// Stacks of layers (M6): `stacks/<id>.json`.
  final Directory stacksDir;

  /// Transposed / stretched renders (disposable cache, M4).
  final RenderCache renders;

  /// Takes, newest first.
  List<Take> list() {
    final takes = <Take>[];
    for (final f in sources.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (!name.endsWith('.wav')) continue;
      final id = name.substring(0, name.length - 4);
      final stat = f.statSync();
      final frames = (stat.size - _wavHeaderBytes) ~/ 4;
      if (frames <= 0) continue; // never got audio; ignore
      final edits = loadEdits(id, frames);
      takes.add(
        Take(
          id,
          f,
          peaksFile(id),
          _createdFromId(id) ?? stat.modified,
          frames,
          editedFrames: edits.isWhole(frames) ? null : edits.length,
        ),
      );
    }
    takes.sort((a, b) => b.created.compareTo(a.created));
    return takes;
  }

  /// Paths for a new take, named after the current time.
  ({String id, String wav, String peaks}) newTake() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    var id =
        'take-${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    var n = 2;
    while (File('${sources.path}/$id.wav').existsSync()) {
      id = '${id.split('_').first}_${n++}';
    }
    return (id: id, wav: '${sources.path}/$id.wav', peaks: peaksFile(id).path);
  }

  File peaksFile(String id) => File('${peaksDir.path}/$id.bin');

  /// Round-trip latency per audio route (loop pedal, M5a). Stored with the
  /// project for now; device-wide settings arrive with projects (M8).
  File get calibrationFile => File('${sources.parent.path}/calibration.json');

  File editsFile(String id) => File('${editsDir.path}/$id.json');

  /// The take's edit list; the whole recording if unedited or unreadable.
  ///
  /// With [clamp] (a stack's mix, whose length changes with its layers),
  /// clips past the end are shortened or dropped instead of rejecting the
  /// whole list.
  EditList loadEdits(String id, int recordingFrames, {bool clamp = false}) {
    final f = editsFile(id);
    if (f.existsSync()) {
      try {
        var e = EditList.fromJsonString(f.readAsStringSync());
        if (clamp) {
          e = EditList([
            for (final c in e.clips)
              if (c.start < recordingFrames)
                c.copyWith(end: math.min(c.end, recordingFrames)),
          ], tune: e.tune);
        }
        // Ignore a list pointing past the recording (damaged file).
        final ok = e.clips.every((c) => c.end <= recordingFrames);
        if (ok && e.clips.isNotEmpty) return e;
      } on FormatException {
        // fall through to the whole recording
      }
    }
    return EditList.whole(recordingFrames);
  }

  /// Saves the edit list; an unedited take keeps no file. Written to a
  /// temporary file and renamed, so a crash never leaves half a file.
  void saveEdits(Take take, EditList edits) {
    final f = editsFile(take.editsId);
    if (edits.isWhole(take.frames)) {
      if (f.existsSync()) f.deleteSync();
      return;
    }
    File('${f.path}.tmp')
      ..writeAsStringSync(edits.toJsonString())
      ..renameSync(f.path);
  }

  /// Loads a take's peaks, rebuilding them in the background if missing or
  /// damaged (e.g. the app was killed mid-take).
  Future<Peaks> loadPeaks(Take take) async {
    if (take.peaks.existsSync()) {
      final p = Peaks.parse(await take.peaks.readAsBytes());
      if (p != null && p.blocks * p.blockFrames >= take.frames) return p;
    }
    final wav = take.wav.path, out = take.peaks.path;
    await Isolate.run(() => PocketAudio.buildPeaks(wav, out));
    return Peaks.parse(await take.peaks.readAsBytes())!;
  }

  // ---- stacks (M6) ----

  List<LayerStack> listStacks() {
    final out = <LayerStack>[];
    for (final f in stacksDir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (!name.endsWith('.json')) continue;
      try {
        out.add(
          LayerStack.fromJsonString(
            name.substring(0, name.length - 5),
            f.readAsStringSync(),
          ),
        );
      } on FormatException {
        // skip a damaged file
      }
    }
    out.sort((a, b) => b.created.compareTo(a.created));
    return out;
  }

  LayerStack newStack() {
    final now = DateTime.now();
    var id = 'stack-${now.millisecondsSinceEpoch}';
    while (File('${stacksDir.path}/$id.json').existsSync()) {
      id = '${id}x';
    }
    final s = LayerStack(id, now, const []);
    saveStack(s);
    return s;
  }

  void saveStack(LayerStack s) {
    final f = File('${stacksDir.path}/${s.id}.json');
    File('${f.path}.tmp')
      ..writeAsStringSync(s.toJsonString())
      ..renameSync(f.path);
  }

  void deleteStack(LayerStack s) {
    final f = File('${stacksDir.path}/${s.id}.json');
    if (f.existsSync()) f.deleteSync();
    _deleteMixes(s.id);
    final e = editsFile(s.id);
    if (e.existsSync()) e.deleteSync();
  }

  // ---- editing a whole stack (M6) ----

  /// Where the stack's combined mix lives. The name carries a hash of
  /// everything that shapes the mix (the arrangement and every layer's
  /// edits), so a changed stack gets a fresh mix and renders/peaks of an old
  /// one are never reused.
  String stackMixPath(LayerStack s) {
    final parts = StringBuffer(s.toJsonString());
    for (final l in s.layers) {
      final f = editsFile(l.takeId);
      parts.write(f.existsSync() ? f.readAsStringSync() : l.takeId);
    }
    final hash = parts.toString().hashCode.toUnsigned(32).toRadixString(16);
    return '${stacksDir.path}/${s.id}.mix-$hash.wav';
  }

  /// The stack's mix as a take for the editor (after the mix file exists).
  Take stackMixTake(LayerStack s, String mixPath) {
    final f = File(mixPath);
    final name = f.uri.pathSegments.last;
    final id = name.substring(0, name.length - 4);
    // Old mixes of this stack are stale now.
    for (final g in stacksDir.listSync().whereType<File>()) {
      final n = g.uri.pathSegments.last;
      if (n.startsWith('${s.id}.mix-') && g.path != mixPath) g.deleteSync();
    }
    return Take(
      id,
      f,
      peaksFile(id),
      s.created,
      (f.lengthSync() - _wavHeaderBytes) ~/ 4,
      editsId: s.id,
    );
  }

  bool stackEdited(LayerStack s) => editsFile(s.id).existsSync();

  void _deleteMixes(String stackId) {
    for (final g in stacksDir.listSync().whereType<File>()) {
      if (g.uri.pathSegments.last.startsWith('$stackId.mix-')) g.deleteSync();
    }
  }

  /// Ids of takes used as layers in any stack.
  Set<String> takesInStacks() => {
    for (final s in listStacks())
      for (final l in s.layers) l.takeId,
  };

  Take? takeById(String id) {
    for (final t in list()) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Deletes a whole take and its edits. (Recordings are never modified —
  /// only removed.) Stacks that used it lose that layer.
  void delete(Take take) {
    if (take.wav.existsSync()) take.wav.deleteSync();
    if (take.peaks.existsSync()) take.peaks.deleteSync();
    final e = editsFile(take.id);
    if (e.existsSync()) e.deleteSync();
    renders.deleteFor(take.id);
    for (final s in listStacks()) {
      if (!s.uses(take.id)) continue;
      saveStack(
        LayerStack(s.id, s.created, [
          for (final l in s.layers)
            if (l.takeId != take.id) l,
        ]),
      );
    }
  }

  static DateTime? _createdFromId(String id) {
    final m = RegExp(r'^take-(\d{4})(\d\d)(\d\d)-(\d\d)(\d\d)(\d\d)')
        .firstMatch(id);
    if (m == null) return null;
    final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
    return DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
  }
}

/// Peaks for an edit list's timeline, assembled from the recording's peaks:
/// one block per [Peaks.blockFrames] timeline frames (display only).
Peaks timelinePeaks(Peaks source, EditList edits) {
  final bf = source.blockFrames;
  final blocks = (edits.length + bf - 1) ~/ bf;
  final out = Float32List(blocks * 2);
  var k = 0, clipStart = 0;
  for (final c in edits.clips) {
    final clipEnd = clipStart + c.length;
    for (; k < blocks && k * bf < clipEnd; k++) {
      final o = k * bf - clipStart;
      final src = c.sourceAt(o);
      final b = (src ~/ bf).clamp(0, source.blocks - 1);
      final g = c.hasFade ? c.gainAt(o + bf ~/ 2) : c.gain;
      out[2 * k] = source.minMax[2 * b] * g;
      out[2 * k + 1] = source.minMax[2 * b + 1] * g;
    }
    clipStart = clipEnd;
  }
  return Peaks(out, bf);
}

/// Where the sound starts in a take (frames of [length]): the first moment
/// the waveform reaches 20 % of its loudest point (and at least 0.01).
/// Recordings often begin with a little silence; layers line up on this.
int soundStartFrame(Peaks p, int length) {
  if (p.blocks == 0 || length == 0) return 0;
  double level(int b) => math.max(-p.minMax[2 * b], p.minMax[2 * b + 1]);
  var loudest = 0.0;
  for (var b = 0; b < p.blocks; b++) {
    loudest = math.max(loudest, level(b));
  }
  final threshold = math.max(0.01, loudest * 0.2);
  for (var b = 0; b < p.blocks; b++) {
    if (level(b) >= threshold) return (b / p.blocks * length).round();
  }
  return 0;
}
