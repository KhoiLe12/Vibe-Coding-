// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

/// Dart API for the Pocket Studio C++ audio core.
///
/// See wiki/components/audio-engine.md. All calls here are short and
/// non-blocking except [PocketAudio.start], which opens the audio device.
library;

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'pocket_audio_bindings_generated.dart' as bindings;

/// Thrown when the native audio core reports an error.
class PocketAudioException implements Exception {
  PocketAudioException(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => 'PocketAudioException($code): $message';
}

/// The process-wide audio engine.
abstract final class PocketAudio {
  /// Version of the native core, including the miniaudio version.
  static String get version =>
      bindings.ps_version().cast<Utf8>().toDartString();

  /// Opens the default output device and starts the audio callback.
  static void start() {
    final code = bindings.ps_engine_start();
    switch (code) {
      case bindings.PS_OK:
        return;
      case bindings.PS_ERROR_ALREADY_RUNNING:
        throw PocketAudioException(code, 'engine already running');
      default:
        throw PocketAudioException(code, 'could not open the audio device');
    }
  }

  /// Stops the callback and closes the device. Safe to call when stopped.
  static void stop() => bindings.ps_engine_stop();

  static bool get isRunning => bindings.ps_engine_is_running() != 0;

  /// Device sample rate, or 0 when stopped.
  static int get sampleRate => bindings.ps_engine_sample_rate();

  /// Audio callbacks served since [start].
  static int get callbackCount => bindings.ps_engine_callback_count();

  /// Sets the test tone. [amplitude] is linear, 0 (silent) to 1 (full scale).
  /// Changes are ramped on the audio thread, so they never click.
  static void setTone({required double frequencyHz, required double amplitude}) =>
      bindings.ps_tone_set(frequencyHz, amplitude);

  /// Renders the tone without a device, as interleaved float samples.
  static Float32List renderToneOffline({
    required int frames,
    required int channels,
    required int sampleRate,
    required double frequencyHz,
    required double amplitude,
  }) {
    final length = frames * channels;
    final buffer = calloc<ffi.Float>(length);
    try {
      bindings.ps_tone_render_offline(
          buffer, frames, channels, sampleRate, frequencyHz, amplitude);
      return Float32List.fromList(buffer.asTypedList(length));
    } finally {
      calloc.free(buffer);
    }
  }
}
