// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Round-trip latency per audio route, for latency-compensated overdubs
// (wiki/concepts/latency-compensation.md, wiki/decisions/d014-looper-m5a.md).
// Measured with the M2 chirp probe; the median of several chirps is used,
// because single readings occasionally misfire (d010).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pocket_audio/pocket_audio.dart';

class Calibration {
  Calibration(this.file);

  final File file;

  Map<String, int> _load() {
    try {
      final j = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return {for (final e in j.entries) e.key: e.value as int};
    } on Object {
      return {};
    }
  }

  /// Saved round trip (frames) for [route], or null if never measured.
  int? framesFor(String route) => _load()[route];

  void save(String route, int frames) {
    final all = _load()..[route] = frames;
    File('${file.path}.tmp')
      ..writeAsStringSync(jsonEncode(all))
      ..renameSync(file.path);
  }

  /// Runs the chirp probe for about [duration] (engine must be running with
  /// input) and returns the median round trip in frames, or null if too few
  /// chirps were heard.
  static Future<int?> measure({
    Duration duration = const Duration(seconds: 4),
  }) async {
    PocketAudio.startLatencyProbe(intervalMs: 450);
    await Future<void>.delayed(duration);
    PocketAudio.stopLatencyProbe();
    final n = PocketAudio.latencyCount;
    if (n < 5) return null;
    final ms = PocketAudio.latencyResults(0, n).toList()..sort();
    final median = ms[ms.length ~/ 2];
    return (median * 48).round(); // 48 frames per ms
  }
}
