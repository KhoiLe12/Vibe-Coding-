// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_audio/pocket_audio.dart' show PlayClip;
import 'package:pocket_studio/edit/edit_list.dart';
import 'package:pocket_studio/edit/render_cache.dart';

void main() {
  late Directory dir;
  late RenderCache cache;
  const tune = Tune(semitones: 3.5, tempo: 1.25);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ps_rc_');
    cache = RenderCache(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('needed range = used clips plus margin, clamped', () {
    final e = EditList([const Clip(100000, 150000), const Clip(30000, 40000)]);
    expect(RenderCache.neededRange(e, 200000), (
      start: 30000 - renderMarginFrames,
      end: 150000 + renderMarginFrames,
    ));
    expect(RenderCache.neededRange(EditList.whole(1000), 1000), (
      start: 0,
      end: 1000,
    ));
  });

  test('finds a render that covers the range, for the same tune only', () {
    final r = cache.planFor('take-1', tune, 0, 96000);
    File(r.path).writeAsBytesSync([0]);
    expect(cache.find('take-1', tune, 1000, 50000)?.path, r.path);
    expect(
      cache.find('take-1', tune, 1000, 97000),
      isNull,
      reason: 'too short',
    );
    expect(cache.find('take-1', const Tune(semitones: 3), 1000, 50000), isNull);
    expect(cache.find('take-2', tune, 1000, 50000), isNull);
  });

  test('clips map into render frames by the tempo', () {
    const r = Render('x', 24000, 120000, tune);
    final e = EditList([const Clip(48000, 72000)], tune: tune);
    expect(r.clipsFor(e).single, const PlayClip(19200, 38400));
  });

  test('deleteFor and trim keep the cache tidy', () {
    for (var i = 0; i < 3; i++) {
      final r = cache.planFor('take-$i', tune, 0, 10);
      File(r.path).writeAsBytesSync(List.filled(1000, 0));
    }
    File(cache.planFor('take-0_2', tune, 0, 10).path).writeAsBytesSync([0]);
    cache.deleteFor('take-0');
    expect(dir.listSync().length, 3, reason: "take-0_2's render survives");
    cache.deleteFor('take-0_2');
    expect(dir.listSync().length, 2);
    cache.trim(maxBytes: 1000);
    expect(dir.listSync().length, 1);
  });
}
