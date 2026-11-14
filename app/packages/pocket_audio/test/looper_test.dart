// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Loop pedal engine against the M5 acceptance criteria
// (wiki/features/loop-pedal.md, wiki/decisions/d014-looper-m5a.md), driven
// through a simulated room: whatever the looper plays comes back into the
// "mic" D frames later (speaker bleed), like a real device with a D-frame
// round trip.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pocket_audio/pocket_audio.dart';
import 'package:test/test.dart';

const sr = 48000;
const block = 64; // the duplex buffer size on the iPhone (d010)

/// A room with a fixed round trip: output comes back as input [delay]
/// frames later, scaled by [bleed], plus whatever the performer plays.
class Room {
  Room(this.delay, {this.bleed = 0.0});

  final int delay;
  final double bleed;
  final _history = <double>[];

  /// Frames run so far (the shared callback counter).
  int get now => _history.length;

  /// Runs [frames] frames; [performer] adds the "played" sound at absolute
  /// frame t (before it reaches the mic, i.e. already including the delay).
  Float32List run(int frames, {double Function(int t)? performer}) {
    final out = Float32List(frames);
    for (var i = 0; i < frames; i += block) {
      final n = math.min(block, frames - i);
      final input = Float32List(n);
      for (var k = 0; k < n; k++) {
        final t = now + k;
        final src = t - delay;
        input[k] =
            (src >= 0 && src < _history.length ? _history[src] * bleed : 0) +
            (performer?.call(t) ?? 0);
      }
      final y = Looper.processOffline(input);
      _history.addAll(y);
      out.setAll(i, y);
    }
    return out;
  }
}

double sine(int t) => 0.5 * math.sin(2 * math.pi * 330 * t / sr);
const sineStep = 0.5 * 2 * math.pi * 330 / sr;

double maxJump(Float32List x) {
  var m = 0.0;
  for (var i = 1; i < x.length; i++) {
    m = math.max(m, (x[i] - x[i - 1]).abs());
  }
  return m;
}

/// Lets the looper's service thread (or us) prepare layer buffers.
void prepare() {
  for (var i = 0; i < 3; i++) {
    Looper.service();
  }
}

/// Presses Overdub (the loop restarts from the top) and runs until the layer
/// has added itself (one pass + the 10 ms seam). [performer] gets the
/// absolute frame and the frame at which the loop restarted.
void overdub(Room room, {double Function(int t, int restart)? performer}) {
  prepare();
  final before = Looper.layers;
  Looper.press();
  final restart = room.now; // the next callback starts at loop position 0
  double play(int t) => performer?.call(t, restart) ?? 0.0;
  room.run(block, performer: play);
  expect(Looper.state, isIn([LooperState.armed, LooperState.overdubbing]));
  var guard = 0;
  while (Looper.layers == before) {
    room.run(block, performer: play);
    if (++guard > 100000) fail('overdub never finished');
  }
}

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ps_loop_');
    // Settings outlive enable/disable: start each test from neutral, before
    // enabling (enable() starts the smoothed gains at these values).
    Looper.latencyFrames = 0;
    Looper.inputGain = 1;
    Looper.outputGain = 1;
    Looper.resetClip();
    Looper.enable();
  });
  tearDown(() {
    Looper.disable();
    dir.deleteSync(recursive: true);
  });

  test('first take sets the loop; the restart has no gap or click', () {
    final room = Room(0);
    Looper.press(); // record
    room.run(64);
    expect(Looper.state, LooperState.recording);
    // A sine at an awkward length: the loop boundary lands mid-cycle.
    room.run(sr ~/ 2 + 37 - 64, performer: sine);
    Looper.press(); // close
    room.run(sr ~/ 50, performer: sine); // the 10 ms seam tail
    expect(Looper.state, LooperState.playing);
    final len = Looper.length;
    expect(
      len,
      closeTo(sr ~/ 2 + 37, block),
      reason: 'as long as it was played (to the callback)',
    );
    final out = room.run(len * 3);
    // Across every restart: no jump larger than the sine's own.
    expect(maxJump(out), lessThan(sineStep * 1.5));
    // And it really repeats with the loop period.
    for (var i = 1000; i < len; i += 997) {
      expect(out[i + len], closeTo(out[i], 1e-6));
    }
  });

  test('overdub of a clap lines up within 1 ms after calibration', () {
    for (final delay in [0, 1061, 4800]) {
      Looper.clear();
      final room = Room(delay, bleed: 0.0);
      Looper.latencyFrames = delay; // calibrated round trip
      // Base take: a click 0.25 s into a 1 s loop.
      const clickAt = sr ~/ 4;
      Looper.press();
      room.run(sr, performer: (t) => t - 0 == clickAt ? 1.0 : 0.0);
      Looper.press();
      room.run(sr ~/ 50);
      final len = Looper.length;
      room.run(len ~/ 3); // press Overdub mid-loop: the loop restarts
      // The performer claps exactly when they hear the click, so the clap
      // reaches the mic one round trip after the click was played.
      overdub(
        room,
        performer: (t, restart) {
          final pos = (t - delay - restart) % len;
          return t - delay >= restart && pos == clickAt ? 0.8 : 0.0;
        },
      );
      expect(Looper.state, LooperState.playing);
      expect(Looper.layers, 2);
      // Mute the base take and bounce: only the overdub's clap remains.
      Looper.setLayerGain(0, 0);
      final path = '${dir.path}/b.wav';
      Looper.bounce(path);
      Looper.setLayerGain(0, 1);
      final y = Float32List.view(
        Uint8List.fromList(File(path).readAsBytesSync().sublist(58)).buffer,
      );
      var best = 0;
      for (var i = 0; i < y.length; i++) {
        if (y[i].abs() > y[best].abs()) best = i;
      }
      expect(y[best].abs(), greaterThan(0.5), reason: 'clap recorded');
      expect(
        (best - clickAt).abs(),
        lessThanOrEqualTo(sr ~/ 1000),
        reason: 'delay $delay: clap at $best, click at $clickAt',
      );
    }
  });

  test('undo and redo of a layer are instant', () {
    final room = Room(0);
    Looper.press();
    room.run(sr ~/ 2, performer: (_) => 0.0);
    Looper.press();
    room.run(sr ~/ 50);
    overdub(room, performer: (_, _) => 0.25); // two layers, steady tone
    overdub(room, performer: (_, _) => 0.25);
    expect(Looper.layers, 3);
    final before = Looper.layers;
    // Each undo takes effect on the very next callback.
    for (var k = 1; k < before; k++) {
      Looper.undo();
      room.run(block);
      expect(Looper.layers, before - k, reason: 'undo $k');
      expect(Looper.redoable, k);
    }
    // With every overdub undone, only the (silent) first take remains:
    // quiet within 5 ms, via the click-free ramp.
    final quiet = room.run(sr ~/ 100);
    expect(quiet.sublist(sr ~/ 200).every((v) => v.abs() < 1e-6), isTrue);
    for (var k = 1; k < before; k++) {
      Looper.redo();
      room.run(block);
    }
    expect(Looper.layers, before);
    expect(Looper.redoable, 0);
  });

  test('a new overdub after undo drops the undone layer (no redo)', () {
    final room = Room(0);
    Looper.press();
    room.run(sr ~/ 4);
    Looper.press();
    room.run(sr ~/ 50);
    overdub(room, performer: (_, _) => 0.1);
    Looper.undo();
    room.run(block);
    expect(Looper.redoable, 1);
    overdub(room, performer: (_, _) => 0.1);
    expect(Looper.redoable, 0);
    expect(Looper.layers, 2);
  });

  test('20 layers keep up with real time (host CPU check)', () {
    final room = Room(0);
    Looper.press();
    room.run(sr, performer: sine);
    Looper.press();
    room.run(sr ~/ 50);
    for (var k = 0; k < 20; k++) {
      overdub(room, performer: (t, _) => sine(t));
    }
    expect(Looper.layers, 21);
    final sw = Stopwatch()..start();
    room.run(sr * 5); // 5 s of 20-layer playback
    final ms = sw.elapsedMilliseconds;
    // ignore: avoid_print
    print('20 layers: 5 s of audio processed in $ms ms on the host');
    expect(ms, lessThan(5000), reason: 'faster than real time');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('overdub without a prepared buffer is refused, not a crash', () {
    Looper.disable();
    Looper.enable();
    final room = Room(0);
    Looper.press();
    room.run(sr ~/ 4);
    Looper.press();
    room.run(sr ~/ 50);
    // Press immediately: the service thread may not have run yet.
    Looper.press();
    room.run(block);
    expect(
      Looper.state == LooperState.armed ||
          Looper.state == LooperState.overdubbing ||
          Looper.starved,
      isTrue,
    );
  });

  test('clear and re-record at another length: overdubs stay in bounds', () {
    for (final secs in [1.0, 0.3, 1.7]) {
      Looper.clear();
      final room = Room(0);
      room.run(block);
      Looper.press();
      room.run((sr * secs).round(), performer: sine);
      Looper.press();
      room.run(sr ~/ 50);
      overdub(room, performer: (t, _) => sine(t));
      expect(Looper.length, closeTo(sr * secs, block));
      expect(Looper.layers, 2);
    }
  });

  test('bounce writes the mix for the requested number of passes', () {
    final room = Room(0);
    Looper.press();
    room.run(sr ~/ 2, performer: sine);
    Looper.press();
    room.run(sr ~/ 50);
    final path = '${dir.path}/b.wav';
    Looper.bounce(path, passes: 4);
    expect((File(path).lengthSync() - 58) ~/ 4, Looper.length * 4);
  });

  test(
    'mic gain scales what is recorded; loop volume only what is heard',
    () async {
      final room = Room(0);
      Looper.inputGain = 4; // +12 dB
      room.run(sr ~/ 2); // settle (~40 ms time constant)
      Looper.press();
      room.run(sr ~/ 2, performer: (_) => 0.1);
      Looper.press();
      room.run(sr ~/ 50);
      final path = '${dir.path}/g.wav';
      Looper.bounce(path);
      final y = Float32List.view(
        Uint8List.fromList(File(path).readAsBytesSync().sublist(58)).buffer,
      );
      expect(y[y.length ~/ 2], closeTo(0.4, 1e-3), reason: 'recorded at ×4');

      Looper.outputGain = 2;
      room.run(sr ~/ 2); // settle
      final heard = room.run(1000);
      expect(heard[500], closeTo(0.8, 1e-3), reason: 'played at ×2');
      Looper.bounce(path);
      final again = Float32List.view(
        Uint8List.fromList(File(path).readAsBytesSync().sublist(58)).buffer,
      );
      expect(
        again[again.length ~/ 2],
        closeTo(0.4, 1e-3),
        reason: 'bounce ignores the playback volume',
      );
    },
  );

  test(
    'loud playback is soft-limited below full scale; clipping is flagged',
    () {
      final room = Room(0);
      Looper.inputGain = 20; // 0.1 × 20 = 2.0: clips
      room.run(sr ~/ 2);
      Looper.press();
      room.run(sr ~/ 2, performer: (_) => 0.1);
      expect(Looper.clipped, isTrue);
      Looper.press();
      room.run(sr ~/ 50);
      final heard = room.run(2000);
      expect(heard.every((v) => v.abs() < 1.0), isTrue);
      expect(heard[1000], greaterThan(0.95), reason: 'limited, not muted');
    },
  );

  test('Overdub restarts the loop at once, without a click', () {
    final room = Room(0);
    Looper.press();
    room.run(sr ~/ 2, performer: sine);
    Looper.press();
    room.run(sr ~/ 50);
    final len = Looper.length;
    final before = room.run(len ~/ 3 + 17); // mid-loop, awkward phase
    prepare();
    Looper.press();
    final after = room.run(block * 4);
    expect(Looper.position, lessThan(block * 5), reason: 'restarted at 0');
    expect(Looper.state, LooperState.overdubbing, reason: 'recording at once');
    final joined = Float32List.fromList([
      ...before.sublist(before.length - 500),
      ...after,
    ]);
    expect(maxJump(joined), lessThan(sineStep * 1.5));
  });

  test('each overdub layer covers exactly one pass, then adds itself', () {
    final room = Room(0);
    Looper.press();
    room.run(sr ~/ 2); // silent first take
    Looper.press();
    room.run(sr ~/ 50);
    final len = Looper.length;
    room.run(len ~/ 3);
    overdub(room, performer: (_, _) => 0.1); // no second press needed
    expect(Looper.layers, 2);
    expect(Looper.state, LooperState.playing);
    // The layer is the steady tone everywhere — start, middle, end — so it
    // lines up with the first take end to end.
    final path = '${dir.path}/s.wav';
    Looper.setLayerGain(0, 0);
    Looper.bounce(path);
    final y = Float32List.view(
      Uint8List.fromList(File(path).readAsBytesSync().sublist(58)).buffer,
    );
    for (final i in [600, len ~/ 2, len - 1]) {
      expect(y[i], closeTo(0.1, 1e-4), reason: 'frame $i');
    }
  });

  test('pressing again while armed or recording cancels the layer', () {
    final room = Room(0);
    Looper.press();
    room.run(sr ~/ 2);
    Looper.press();
    room.run(sr ~/ 50);
    Looper.latencyFrames = 4800; // armed for 100 ms before recording
    prepare();
    Looper.press(); // arm
    room.run(block);
    expect(Looper.state, LooperState.armed);
    Looper.press(); // cancel while armed
    room.run(block);
    expect(Looper.state, LooperState.playing);
    expect(Looper.layers, 1);
    prepare();
    Looper.press();
    room.run(4800 + block * 10);
    expect(Looper.state, LooperState.overdubbing);
    Looper.press(); // cancel while recording
    room.run(Looper.length * 2);
    expect(Looper.layers, 1, reason: 'nothing added');
  });

  test('deleting a middle layer removes just that one, without a click', () {
    final room = Room(0);
    Looper.press();
    room.run(sr ~/ 2); // silent first take
    Looper.press();
    room.run(sr ~/ 50);
    for (final level in [0.1, 0.2, 0.4]) {
      overdub(room, performer: (_, _) => level);
    }
    expect(Looper.layers, 4);
    expect(room.run(sr ~/ 50).last, closeTo(0.7, 1e-4)); // new layer faded in
    Looper.deleteLayer(2); // the 0.2 layer
    final fade = room.run(sr ~/ 50);
    expect(Looper.layers, 3);
    expect(fade.last, closeTo(0.5, 1e-4), reason: '0.1 + 0.4 remain');
    expect(maxJump(fade), lessThan(0.2 / 200), reason: 'faded, not cut');
    // The first take can't be deleted; undo still takes the newest (0.4).
    Looper.deleteLayer(0);
    room.run(block);
    expect(Looper.layers, 3);
    Looper.undo();
    expect(room.run(sr ~/ 50).last, closeTo(0.1, 1e-4));
  });
}
