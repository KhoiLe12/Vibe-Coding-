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

/// Microphone permission state.
enum MicPermission { undetermined, granted, denied }

/// The process-wide audio engine.
abstract final class PocketAudio {
  /// Version of the native core, including the miniaudio version.
  static String get version =>
      bindings.ps_version().cast<Utf8>().toDartString();

  /// Opens the default output device and starts the audio callback.
  /// With [input], also opens the microphone (full duplex); see
  /// [micPermission].
  static void start({bool input = false}) {
    final code = bindings.ps_engine_start_ex(input ? 1 : 0);
    switch (code) {
      case bindings.PS_OK:
        return;
      case bindings.PS_ERROR_ALREADY_RUNNING:
        throw PocketAudioException(code, 'engine already running');
      case bindings.PS_ERROR_NO_PERMISSION:
        throw PocketAudioException(code, 'microphone permission not granted');
      default:
        throw PocketAudioException(code, 'could not open the audio device');
    }
  }

  /// Whether the engine is running with the microphone open.
  static bool get hasInput => bindings.ps_engine_has_input() != 0;

  /// OS audio interruptions (calls, Siri, other apps) since launch. The
  /// engine restarts by itself when one ends.
  static int get interruptionCount => bindings.ps_engine_interruption_count();

  /// Microphone permission as known to the native core (iOS). Android asks
  /// in the app shell, so this reports granted there.
  static MicPermission get micPermission =>
      switch (bindings.ps_mic_permission()) {
        bindings.PS_MIC_GRANTED => MicPermission.granted,
        bindings.PS_MIC_DENIED => MicPermission.denied,
        _ => MicPermission.undetermined,
      };

  /// Shows the OS prompt if not yet answered; poll [micPermission].
  static void requestMicPermission() => bindings.ps_mic_request_permission();

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

  // ---- Input stage + recorder (M1) ----

  /// Frames per (min, max) pair in live and stored peaks.
  static int get peakBlockFrames => bindings.ps_peaks_block_frames();

  /// Input gain, linear (1 = unity). Smoothed on the audio thread.
  static set inputGain(double linear) => bindings.ps_input_set_gain(linear);

  /// Highest absolute post-gain input sample since the previous read.
  static double takeInputPeak() => bindings.ps_input_take_peak_level();

  /// Whether the input reached full scale since [resetClip].
  static bool get clipped => bindings.ps_input_clipped() != 0;
  static void resetClip() => bindings.ps_input_reset_clip();

  /// Feeds mono samples through the input stage, exactly as the microphone
  /// callback does. For tests and tools.
  static void processInput(Float32List mono) {
    final buffer = calloc<ffi.Float>(mono.length);
    try {
      buffer.asTypedList(mono.length).setAll(0, mono);
      bindings.ps_input_process(buffer, mono.length);
    } finally {
      calloc.free(buffer);
    }
  }

  /// Starts a take written to [wavPath] (mono 32-bit float WAV).
  static void beginRecording(String wavPath, {int sampleRate = 48000}) {
    final path = wavPath.toNativeUtf8();
    try {
      _check(bindings.ps_recorder_begin(path.cast(), sampleRate),
          'could not start recording to $wavPath');
    } finally {
      calloc.free(path);
    }
  }

  /// Finishes the take and writes its peaks file to [peaksPath] (if given).
  static void endRecording({String? peaksPath}) {
    final path = (peaksPath ?? '').toNativeUtf8();
    try {
      _check(bindings.ps_recorder_end(path.cast()), 'could not finish the take');
    } finally {
      calloc.free(path);
    }
  }

  static bool get isRecording => bindings.ps_recorder_is_recording() != 0;
  static bool get isPaused => bindings.ps_recorder_is_paused() != 0;
  static set paused(bool value) =>
      bindings.ps_recorder_set_paused(value ? 1 : 0);

  static int get framesWritten => bindings.ps_recorder_frames_written();
  static int get droppedFrames => bindings.ps_recorder_dropped_frames();
  static bool get writeError => bindings.ps_recorder_write_error() != 0;

  static int get livePeakBlockCount => bindings.ps_recorder_peak_block_count();

  /// Live waveform peaks as interleaved (min, max) pairs.
  static Float32List copyLivePeaks(int firstBlock, int maxBlocks) {
    if (maxBlocks <= 0) return Float32List(0);
    final buffer = calloc<ffi.Float>(maxBlocks * 2);
    try {
      final n = bindings.ps_recorder_copy_peaks(buffer, firstBlock, maxBlocks);
      return Float32List.fromList(buffer.asTypedList(n * 2));
    } finally {
      calloc.free(buffer);
    }
  }

  static void _check(int code, String message) {
    switch (code) {
      case bindings.PS_OK:
        return;
      case bindings.PS_ERROR_ALREADY_RUNNING:
        throw PocketAudioException(code, 'already recording');
      case bindings.PS_ERROR_NOT_RECORDING:
        throw PocketAudioException(code, 'not recording');
      default:
        throw PocketAudioException(code, message);
    }
  }

  // ---- Player (M1) ----

  /// Opens a take for playback, paused at the start.
  static void openTake(String wavPath) {
    final path = wavPath.toNativeUtf8();
    try {
      _check(bindings.ps_player_open(path.cast()), 'could not open $wavPath');
    } finally {
      calloc.free(path);
    }
  }

  static void closeTake() => bindings.ps_player_close();
  static bool get isPlaying => bindings.ps_player_is_playing() != 0;
  static set playing(bool value) =>
      bindings.ps_player_set_playing(value ? 1 : 0);
  static bool get playbackFinished => bindings.ps_player_finished() != 0;
  static void seek(int frame) =>
      _check(bindings.ps_player_seek(frame), 'no take open');
  static int get playbackPosition => bindings.ps_player_position();
  static int get takeLength => bindings.ps_player_length();

  /// Runs the player's audio-thread code without a device (tests only).
  static Float32List renderPlayerOffline(int frames, {int channels = 2}) {
    final buffer = calloc<ffi.Float>(frames * channels);
    try {
      bindings.ps_player_render_offline(buffer, frames, channels);
      return Float32List.fromList(buffer.asTypedList(frames * channels));
    } finally {
      calloc.free(buffer);
    }
  }

  /// Rebuilds a take's peaks file from its WAV. Slow for long takes; call
  /// from a background isolate.
  static void buildPeaks(String wavPath, String peaksPath) {
    final w = wavPath.toNativeUtf8();
    final p = peaksPath.toNativeUtf8();
    try {
      _check(bindings.ps_peaks_build(w.cast(), p.cast()),
          'could not build peaks for $wavPath');
    } finally {
      calloc.free(w);
      calloc.free(p);
    }
  }
}
