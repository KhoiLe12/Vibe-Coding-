// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// M7 sampling tools in the edit model and export planning
// (wiki/features/sampling-tools.md, wiki/decisions/d016-sampling-tools.md).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_audio/pocket_audio.dart' show Fades, PlayClip;
import 'package:pocket_studio/edit/edit_list.dart';
import 'package:pocket_studio/edit/render_cache.dart';
import 'package:pocket_studio/edit/sample_export.dart';
import 'package:pocket_studio/takes/take_store.dart';

void main() {
  final whole = EditList.whole(1000);

  group('reverse', () {
    test('reverses clip order and each clip; twice = the original sound', () {
      final e = whole.split(400).reverse(200, 700);
      expect(e.clips, [
        const Clip(0, 200),
        const Clip(400, 700, reverse: true),
        const Clip(200, 400, reverse: true),
        const Clip(700, 1000),
      ]);
      expect(e.length, 1000);
      // Frame by frame, the selection plays backwards.
      for (var t = 200; t < 700; t++) {
        expect(e.sourceAt(t), 699 - (t - 200), reason: 'frame $t');
      }
      final back = e.reverse(200, 700);
      for (var t = 0; t < 1000; t++) {
        expect(back.sourceAt(t), t, reason: 'frame $t');
      }
    });

    test('splitting a reversed clip keeps the sound the same', () {
      final r = whole.reverse(0, 1000);
      final s = r.split(300);
      expect(s.clips, [
        const Clip(700, 1000, reverse: true),
        const Clip(0, 700, reverse: true),
      ]);
      for (var t = 0; t < 1000; t++) {
        expect(s.sourceAt(t), r.sourceAt(t));
      }
    });

    test('reversing mirrors fades (a fade in becomes a fade out)', () {
      final f = whole.setFadeIn(0, 100);
      final r = f.reverse(0, 1000).clips.single;
      expect(r.fadeOutFrames, 100);
      expect(r.fadeInFrames, 0);
      // Sound check: the reversed clip's gain at k equals the original's at
      // the mirrored frame.
      final c = f.clips.single;
      for (final k in [0, 50, 99, 500]) {
        expect(r.gainAt(999 - k), closeTo(c.gainAt(k), 1e-9));
      }
    });
  });

  group('fades (needle)', () {
    test('fade in / out set lengths on one clip without splitting it', () {
      final f = whole.setFadeIn(0, 200).setFadeOut(0, 300);
      expect(f.clips.length, 1);
      final c = f.clips.single;
      expect((c.fadeInFrames, c.fadeOutFrames), (200, 300));
      expect(c.gainAt(0), lessThan(1e-4));
      expect(c.gainAt(100), closeTo(0.5, 0.01));
      expect(c.gainAt(500), 1);
      expect(c.gainAt(999), lessThan(1e-4));
      // Moving the needle again replaces only that fade.
      final g = f.setFadeIn(0, 50);
      expect(
        (g.clips.single.fadeInFrames, g.clips.single.fadeOutFrames),
        (50, 300),
      );
      expect(f.setFadeIn(0, 0).clips.single.fadeInFrames, 0);
      expect(f.setFadeIn(0, 5000).clips.single.fadeInFrames, 1000);
    });

    test('splitting inside a fade keeps every frame\'s gain', () {
      final f = whole.setFadeIn(0, 400).setFadeOut(0, 400);
      final s = f.split(250).split(800);
      expect(s.clips.length, 3);
      for (var t = 0; t < 1000; t++) {
        final l = s.locate(t);
        expect(
          s.clips[l.index].gainAt(l.offset),
          closeTo(f.clips.single.gainAt(t), 1e-9),
          reason: 'frame $t',
        );
      }
    });

    test('a fade on one clip of a chopped take leaves the others alone', () {
      final e = whole.split(500).setFadeOut(0, 100);
      expect(e.clips[0].fadeOutFrames, 100);
      expect(e.clips[1].hasFade, isFalse);
    });

    test('remove fades clears the clips it overlaps', () {
      final f = whole.split(500).setFadeIn(0, 100).setFadeOut(1, 100);
      final c = f.clearFades(0, 100);
      expect(c.clips.first.hasFade, isFalse);
      expect(c.clips.last.hasFade, isTrue);
      expect(f.hasFadeOver(600, 700), isTrue);
      expect(whole.hasFadeOver(0, 1000), isFalse);
    });

    test('first-build envelopes load as the same curve', () {
      // {"env": [0, 1]} across a 1000-frame clip = fade in over all of it;
      // [0.5, 1] = the second half of a fade that began 1000 frames earlier.
      Clip load(String env) => Clip.fromJson({
        'start': 0,
        'end': 1000,
        'gain': 1.0,
        'env': [for (final v in env.split(',')) double.parse(v)],
      });
      expect(load('0,1').fades, const Fades(inA: 0, inB: 1000));
      expect(load('0.5,1').fades, const Fades(inA: -1000, inB: 1000));
      expect(load('1,0').fades, const Fades(outA: 0, outB: 1000));
    });
  });

  group('region fades (handles)', () {
    double gainAt(EditList e, int t) {
      final l = e.locate(t);
      return e.clips[l.index].gainAt(l.offset);
    }

    test('whole take: one curve across a chopped take, no new splits', () {
      final chopped = whole.split(300).split(600);
      final e = chopped.fadeRegionIn(0, 1000, 500).fadeRegionOut(0, 1000, 200);
      expect(e.clips.length, 3);
      expect(e.regionFadeIn(0, 1000), 500);
      expect(e.regionFadeOut(0, 1000), 200);
      // Same gains as one clip with the same fades.
      final one = whole.setFadeIn(0, 500).setFadeOut(0, 200);
      for (var t = 0; t < 1000; t++) {
        expect(gainAt(e, t), closeTo(gainAt(one, t), 1e-9), reason: 'frame $t');
      }
    });

    test('selection: starts at its edges, the audio outside is untouched', () {
      final e = whole.fadeRegionIn(200, 700, 100).fadeRegionOut(200, 700, 50);
      expect(e.regionFadeIn(200, 700), 100);
      expect(e.regionFadeOut(200, 700), 50);
      for (final t in [0, 199, 700, 999]) {
        expect(gainAt(e, t), 1.0, reason: 'frame $t');
      }
      expect(gainAt(e, 200), lessThan(0.001));
      expect(gainAt(e, 450), 1.0);
      expect(gainAt(e, 699), lessThan(0.01));
    });

    test('changing and removing a fade replaces it on every clip', () {
      final chopped = whole.split(300);
      final long = chopped.fadeRegionIn(0, 1000, 600);
      final short = long.fadeRegionIn(0, 1000, 100);
      expect(short.regionFadeIn(0, 1000), 100);
      expect(short.clips[1].hasFade, isFalse);
      final none = long.fadeRegionIn(0, 1000, 0);
      expect(none.clips.every((c) => !c.hasFade), isTrue);
      expect(none.clips.length, 2);
      // Removing on a selection with no fade doesn't split anything.
      expect(whole.fadeRegionIn(200, 700, 0).clips.length, 1);
    });

    test('a fade is clamped to its region', () {
      expect(whole.fadeRegionIn(200, 700, 9000).regionFadeIn(200, 700), 500);
    });
  });

  test('scaleGain multiplies only the range', () {
    final g = whole.scaleGain(200, 400, 2);
    expect(g.clips.map((c) => c.gain), [1, 2, 1]);
    expect(whole.scaleGain(0, 1000, 1), same(whole));
  });

  test('every tool is undoable through the history', () {
    final h = EditHistory(whole);
    h.push('Reverse', h.current.reverse(0, 500));
    h.push('Fade in', h.current.setFadeIn(0, 100));
    h.push('Normalize', h.current.scaleGain(0, 1000, 1.5));
    h.push('Varispeed', h.current.withTune(const Tune(varispeed: 7)));
    for (var i = 0; i < 4; i++) {
      h.undo();
    }
    expect(h.current, whole);
  });

  test('JSON v3 round-trips reverse, fades and varispeed; old files load', () {
    final e = whole
        .reverse(0, 300)
        .setFadeOut(1, 200)
        .scaleGain(0, 200, 0.5)
        .withTune(const Tune(semitones: 2, varispeed: -5));
    final back = EditList.fromJsonString(e.toJsonString());
    expect(back, e);
    expect(
      EditList.fromJsonString(
        '{"version":2,"clips":[{"start":0,"end":10,"gain":1.0}],'
        '"tune":{"semitones":1,"tempo":1,"formant":false}}',
      ),
      EditList([const Clip(0, 10)], tune: const Tune(semitones: 1)),
    );
  });

  group('varispeed', () {
    test('speed and time ratio', () {
      expect(const Tune(varispeed: 12).speed, closeTo(2, 1e-12));
      expect(const Tune(varispeed: -24).speed, closeTo(0.25, 1e-12));
      expect(
        const Tune(tempo: 1.25, varispeed: 12).timeRatio,
        closeTo(2.5, 1e-12),
      );
      expect(const Tune(varispeed: 1).isIdentity, isFalse);
      expect(const Tune().copyWith(varispeed: 30).varispeed, 24);
    });

    test('renders are keyed by varispeed and clips map by the ratio', () {
      final dir = Directory.systemTemp.createTempSync('ps_vs_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cache = RenderCache(dir);
      const v = Tune(varispeed: 12);
      final r = cache.planFor('t', v, 0, 96000);
      File(r.path).writeAsBytesSync([0]);
      expect(cache.find('t', v, 0, 96000)?.path, r.path);
      expect(
        cache.find('t', Tune.none.copyWith(semitones: 0.01), 0, 9),
        isNull,
      );
      expect(cache.find('t', const Tune(varispeed: 11), 0, 96000), isNull);
      // An M4 render without varispeed keeps its old name.
      expect(
        cache.planFor('t', const Tune(semitones: 1), 0, 9).path,
        endsWith('t__100_1000_0_0_9.wav'),
      );
      final e = EditList([
        const Clip(48000, 96000, reverse: true, fades: Fades(inB: 4800)),
      ]);
      // Fades scale with the render's time too (×2 speed: half as long).
      expect(
        r.clipsFor(e).single,
        const PlayClip(24000, 48000, reverse: true, fades: Fades(inB: 2400)),
      );
    });
  });

  group('export plan', () {
    final e = EditList([
      const Clip(0, 48000),
      const Clip(96000, 144000),
      const Clip(48000, 96000),
    ]);

    test('one-shot: the whole take, or just the selection', () {
      final all = planExport(
        kind: ExportKind.oneShot,
        edits: e,
        render: null,
        source: 'rec.wav',
        dir: '/x',
        base: 'B',
      );
      expect(all.single.output, '/x/B.wav');
      expect(all.single.clips, [for (final c in e.clips) c.toPlay()]);
      final sel = planExport(
        kind: ExportKind.oneShot,
        edits: e,
        render: null,
        source: 'rec.wav',
        dir: '/x',
        base: 'B',
        range: (start: 24000, end: 72000),
      );
      expect(sel.single.clips, const [
        PlayClip(24000, 48000),
        PlayClip(96000, 120000),
      ]);
    });

    test('loop: carries 10 ms of what follows for the seam', () {
      final p = planExport(
        kind: ExportKind.loop,
        edits: e,
        render: null,
        source: 'rec.wav',
        dir: '/x',
        base: 'B',
        range: (start: 0, end: 48000),
      ).single;
      expect(p.loopFrames, 48000);
      expect(p.clips, const [PlayClip(0, 48000), PlayClip(96000, 96480)]);
      expect(p.output, '/x/B loop.wav');
      // At the end of the take there is nothing to carry: fades instead.
      final end = planExport(
        kind: ExportKind.loop,
        edits: e,
        render: null,
        source: 'rec.wav',
        dir: '/x',
        base: 'B',
      ).single;
      expect(end.loopFrames, 144000);
      expect(end.clips.fold<int>(0, (s, c) => s + c.length), 144000);
    });

    test('loop through a render: lengths in the render\'s frames', () {
      const r = Render('r.wav', 0, 144000, Tune(tempo: 1.5));
      final p = planExport(
        kind: ExportKind.loop,
        edits: e,
        render: r,
        source: 'r.wav',
        dir: '/x',
        base: 'B',
        range: (start: 0, end: 48000),
      ).single;
      expect(p.loopFrames, 32000);
      expect(p.clips.first, const PlayClip(0, 32000));
      expect(p.clips.last.length, 480); // 720 recording frames / 1.5
    });

    test('slices: one file per clip, numbered, limited to the selection', () {
      final all = planExport(
        kind: ExportKind.slices,
        edits: e,
        render: null,
        source: 'rec.wav',
        dir: '/x',
        base: 'B',
      );
      expect(all.map((i) => i.output), [
        '/x/B slice 01.wav',
        '/x/B slice 02.wav',
        '/x/B slice 03.wav',
      ]);
      expect(all[1].clips, const [PlayClip(96000, 144000)]);
      final sel = planExport(
        kind: ExportKind.slices,
        edits: e,
        render: null,
        source: 'rec.wav',
        dir: '/x',
        base: 'B',
        range: (start: 60000, end: 144000),
      );
      expect(sel.length, 2);
      expect(sel.first.clips, const [PlayClip(108000, 144000)]);
    });
  });

  test('sound range: first/last block above the threshold, with margins', () {
    // 10 blocks of 256: silence, sound in blocks 3–6, silence.
    final mm = Float32List(20);
    for (var k = 3; k <= 6; k++) {
      mm[2 * k] = -0.5;
      mm[2 * k + 1] = 0.5;
    }
    mm[2 * 8 + 1] = 0.001; // noise below −48 dB
    final p = Peaks(mm, 256);
    expect(soundRange(p, 2560, dbToGain(-48), pre: 100, post: 100), (
      start: 3 * 256 - 100,
      end: 7 * 256 + 100,
    ));
    expect(soundRange(p, 2560, 0.9), isNull);
    expect(
      soundRange(p, 2560, dbToGain(-48))!.end,
      2560,
      reason: 'clamped to the take',
    );
  });

  test('timeline peaks follow reverse and fades', () {
    final mm = Float32List(8)
      ..setAll(0, [-0.1, 0.1, -0.2, 0.2, -0.3, 0.3, -0.4, 0.4]);
    final src = Peaks(mm, 256);
    final rev = timelinePeaks(
      src,
      EditList([const Clip(0, 1024, reverse: true)]),
    );
    expect(rev.minMax[1], closeTo(0.4, 1e-6));
    expect(rev.minMax[7], closeTo(0.1, 1e-6));
    const c = Clip(0, 1024, fades: Fades(inB: 1024));
    final faded = timelinePeaks(src, EditList([c]));
    expect(faded.minMax[1], lessThan(0.1 * 0.1));
    expect(faded.minMax[7], closeTo(0.4 * c.gainAt(896), 1e-6));
  });
}
