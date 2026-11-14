// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// App-level control of the native engine: which mode it runs in, microphone
// permission, and (Android) the recording foreground service.
// See wiki/components/audio-engine.md.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:pocket_audio/pocket_audio.dart';

abstract final class AudioControl {
  static const _channel = MethodChannel('pocket_studio/platform');

  /// Runs the engine with the microphone open (Record screen). The mic is
  /// only open while it is needed, so the OS recording indicator is honest.
  ///
  /// Mic open ⇒ 64-frame I/O buffers: the only size that meets the M2 latency
  /// gate with miniaudio on iOS (22 ms round trip; wiki/decisions/
  /// d010-duplex-buffer-size.md). [periodFrames] overrides it (Latency screen).
  static const duplexPeriodFrames = 64;
  static const playbackPeriodFrames = 256;

  ///
  /// [raw] (default) keeps the mic unprocessed (iOS measurement mode), which
  /// also makes the speaker quiet; the loop pedal passes false for normal
  /// speaker loudness (wiki/decisions/d014-looper-m5a.md).
  static void useInput({
    int periodFrames = duplexPeriodFrames,
    bool raw = true,
  }) {
    if (PocketAudio.isRunning && PocketAudio.hasInput && _raw == raw) return;
    PocketAudio.stop();
    PocketAudio.periodFrames = periodFrames;
    PocketAudio.rawInput = raw;
    PocketAudio.start(input: true);
    _raw = raw;
  }

  static bool _raw = true;

  /// Runs the engine output-only (playback).
  static void useOutput() {
    if (PocketAudio.isRunning && !PocketAudio.hasInput) return;
    PocketAudio.stop();
    // 256 frames (5.3 ms): keeps tap → sound well under the M2 50 ms
    // criterion (≈ 3 periods + ~10 ms hardware); still light on battery.
    PocketAudio.periodFrames = playbackPeriodFrames;
    PocketAudio.start();
  }

  static void release() => PocketAudio.stop();

  // ---- who owns the player ----
  // A screen's dispose() runs after its exit transition (~300 ms), but the
  // screen underneath resumes as soon as the pop starts — so a closing take
  // editor used to close the player and stop the engine right after the
  // stack below had reopened them (human, 2026-11-14: "add an edited take to
  // a stack… error… exit and back in works"). Screens that open the player
  // claim it; on dispose they tear down only what they still own.
  static int _playerOwner = 0;

  /// Claims the player for the calling screen; returns its token.
  static int claimPlayer() => ++_playerOwner;

  /// Whether [token] still owns the player (no screen claimed it since).
  static bool ownsPlayer(int token) => token == _playerOwner;

  /// Closes the player and stops the engine, if [token] still owns them.
  static void releasePlayer(int token) {
    if (!ownsPlayer(token)) return;
    PocketAudio.closeTake();
    release();
  }

  /// Makes sure playback audio is really flowing, e.g. when play is
  /// pressed or the app comes back. "Running" is not enough: when another
  /// app interrupts our audio, iOS stops it and does not always say when the
  /// interruption is over, so the engine looked running but was silent
  /// (human, 2026-11-14). The audio thread counts its callbacks; if the count
  /// doesn't move within ~80 ms, the engine is restarted (twice at most).
  /// Returns whether audio is flowing.
  static Future<bool> ensureOutput() async {
    if (PocketAudio.isRunning && !PocketAudio.hasInput && await _flowing()) {
      return true;
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        PocketAudio.stop(); // force a fresh start: useOutput() would skip it
        useOutput();
        if (await _flowing()) return true;
      } on PocketAudioException {
        // iOS refused (e.g. still launching): try again shortly.
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  static Future<bool> _flowing() async {
    final before = PocketAudio.callbackCount;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    return PocketAudio.callbackCount != before;
  }

  /// Asks for the microphone if needed. Returns whether it is granted.
  static Future<MicPermission> ensureMic() async {
    if (Platform.isAndroid) {
      final state = await _channel.invokeMethod<String>('requestMicPermission');
      return state == 'granted' ? MicPermission.granted : MicPermission.denied;
    }
    var state = PocketAudio.micPermission;
    if (state != MicPermission.undetermined) return state;
    PocketAudio.requestMicPermission();
    // The prompt answers asynchronously; poll until the user decides.
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (state == MicPermission.undetermined &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      state = PocketAudio.micPermission;
    }
    return state;
  }

  /// Android: keeps the process and mic alive while a take records in the
  /// background. No-op elsewhere (iOS uses the "audio" background mode).
  static Future<void> setRecordingService(bool on) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>(
      on ? 'startRecordingService' : 'stopRecordingService',
    );
  }
}
