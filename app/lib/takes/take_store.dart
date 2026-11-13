// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Takes on disk (wiki/components/storage.md). M1 keeps every take in one
// project folder, "inbox":
//   <documents>/projects/inbox/sources/<id>.wav   immutable recordings
//   <documents>/projects/inbox/peaks/<id>.bin     waveform caches (rebuildable)

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pocket_audio/pocket_audio.dart';

/// Header size of the WAVs our recorder writes (RIFF + fmt + fact + data).
const _wavHeaderBytes = 58;
const sampleRate = 48000;

class Take {
  Take(this.id, this.wav, this.peaks, this.created, this.frames);

  final String id;
  final File wav;
  final File peaks;
  final DateTime created;
  final int frames;

  Duration get duration =>
      Duration(microseconds: frames * 1000000 ~/ sampleRate);
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
      peaksDir = Directory('${projectDir.path}/peaks') {
    sources.createSync(recursive: true);
    peaksDir.createSync(recursive: true);
  }

  final Directory sources;
  final Directory peaksDir;

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
      takes.add(
        Take(id, f, peaksFile(id), _createdFromId(id) ?? stat.modified, frames),
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

  /// Deletes a whole take. (Recordings are never modified — only removed.)
  void delete(Take take) {
    if (take.wav.existsSync()) take.wav.deleteSync();
    if (take.peaks.existsSync()) take.peaks.deleteSync();
  }

  static DateTime? _createdFromId(String id) {
    final m = RegExp(r'^take-(\d{4})(\d\d)(\d\d)-(\d\d)(\d\d)(\d\d)')
        .firstMatch(id);
    if (m == null) return null;
    final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
    return DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
  }
}
