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
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pocket_audio/pocket_audio.dart';

import '../edit/edit_list.dart';
import '../edit/render_cache.dart';

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
  });

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
      renders = RenderCache(Directory('${projectDir.path}/renders')) {
    sources.createSync(recursive: true);
    peaksDir.createSync(recursive: true);
    editsDir.createSync(recursive: true);
  }

  final Directory sources;
  final Directory peaksDir;
  final Directory editsDir;

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

  File editsFile(String id) => File('${editsDir.path}/$id.json');

  /// The take's edit list; the whole recording if unedited or unreadable.
  EditList loadEdits(String id, int recordingFrames) {
    final f = editsFile(id);
    if (f.existsSync()) {
      try {
        final e = EditList.fromJsonString(f.readAsStringSync());
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
    final f = editsFile(take.id);
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

  /// Deletes a whole take and its edits. (Recordings are never modified —
  /// only removed.)
  void delete(Take take) {
    if (take.wav.existsSync()) take.wav.deleteSync();
    if (take.peaks.existsSync()) take.peaks.deleteSync();
    final e = editsFile(take.id);
    if (e.existsSync()) e.deleteSync();
    renders.deleteFor(take.id);
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
      final src = c.start + (k * bf - clipStart);
      final b = (src ~/ bf).clamp(0, source.blocks - 1);
      out[2 * k] = source.minMax[2 * b] * c.gain;
      out[2 * k + 1] = source.minMax[2 * b + 1] * c.gain;
    }
    clipStart = clipEnd;
  }
  return Peaks(out, bf);
}
