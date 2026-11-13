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
  static void useInput() {
    if (PocketAudio.isRunning && PocketAudio.hasInput) return;
    PocketAudio.stop();
    PocketAudio.start(input: true);
  }

  /// Runs the engine output-only (playback).
  static void useOutput() {
    if (PocketAudio.isRunning && !PocketAudio.hasInput) return;
    PocketAudio.stop();
    PocketAudio.start();
  }

  static void release() => PocketAudio.stop();

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
