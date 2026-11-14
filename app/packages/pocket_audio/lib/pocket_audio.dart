// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

/// Dart API for the Pocket Studio C++ audio core.
///
/// See wiki/components/audio-engine.md. All calls here are short and
/// non-blocking except [PocketAudio.start], which opens the audio device.
library;

import 'dart:ffi' as ffi;
import 'dart:math' as math;
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

/// Fades of a clip (M7), in the clip's own frames in timeline order: silent
/// before [inA], fading in to full at [inB]; full until [outA], silent from
/// [outB]. A ramp whose B <= A is off. Positions may lie outside the clip (a
/// split leaves each piece its share of the same curve).
class Fades {
  const Fades({this.inA = 0, this.inB = 0, this.outA = 0, this.outB = 0});

  static const none = Fades();

  final double inA, inB, outA, outB;

  bool get hasIn => inB > inA;
  bool get hasOut => outB > outA;
  bool get any => hasIn || hasOut;

  /// The same curves seen from [k] frames later (the second piece of a
  /// split at k).
  /// Ramps that are off stay at 0, so a clip without fades splits into
  /// clips without fades.
  Fades shift(int k) => Fades(
    inA: hasIn ? inA - k : 0,
    inB: hasIn ? inB - k : 0,
    outA: hasOut ? outA - k : 0,
    outB: hasOut ? outB - k : 0,
  );

  @override
  bool operator ==(Object other) =>
      other is Fades &&
      other.inA == inA &&
      other.inB == inB &&
      other.outA == outA &&
      other.outB == outB;

  @override
  int get hashCode => Object.hash(inA, inB, outA, outB);

  @override
  String toString() =>
      'Fades(${hasIn ? 'in $inA→$inB' : ''}${hasOut ? ' out $outA→$outB' : ''})';
}

/// One clip as the engine plays it: frames [start, end) of a source, with
/// [gain], played backwards if [reverse], with [fades] (M7).
class PlayClip {
  const PlayClip(
    this.start,
    this.end, {
    this.gain = 1.0,
    this.reverse = false,
    this.fades = Fades.none,
  });

  final int start, end;
  final double gain;
  final bool reverse;
  final Fades fades;

  int get length => end - start;

  @override
  bool operator ==(Object other) =>
      other is PlayClip &&
      other.start == start &&
      other.end == end &&
      other.gain == gain &&
      other.reverse == reverse &&
      other.fades == fades;

  @override
  int get hashCode => Object.hash(start, end, gain, reverse, fades);

  @override
  String toString() =>
      'PlayClip($start–$end${gain == 1 ? '' : ' ×$gain'}'
      '${reverse ? ' reversed' : ''}${fades.any ? ' $fades' : ''})';
}

/// Clips copied into native arrays for one call; free with [free].
class _NativeClips {
  _NativeClips(List<PlayClip> clips) : n = clips.length {
    final m = math.max(1, n);
    starts = calloc<ffi.Int64>(m);
    ends = calloc<ffi.Int64>(m);
    gains = calloc<ffi.Float>(m);
    fades = calloc<ffi.Double>(4 * m);
    reverse = calloc<ffi.Uint8>(m);
    for (var i = 0; i < n; i++) {
      final c = clips[i];
      starts[i] = c.start;
      ends[i] = c.end;
      gains[i] = c.gain;
      fades[4 * i] = c.fades.inA;
      fades[4 * i + 1] = c.fades.inB;
      fades[4 * i + 2] = c.fades.outA;
      fades[4 * i + 3] = c.fades.outB;
      reverse[i] = c.reverse ? 1 : 0;
    }
  }

  final int n;
  late final ffi.Pointer<ffi.Int64> starts, ends;
  late final ffi.Pointer<ffi.Float> gains;
  late final ffi.Pointer<ffi.Double> fades;
  late final ffi.Pointer<ffi.Uint8> reverse;

  void free() {
    calloc.free(starts);
    calloc.free(ends);
    calloc.free(gains);
    calloc.free(fades);
    calloc.free(reverse);
  }
}

/// Export bit depth (M7).
enum ExportBits {
  pcm16(16),
  pcm24(24),
  float32(32);

  const ExportBits(this.bits);
  final int bits;
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

  /// iOS, for the next [start] with input: true (default) = measurement
  /// mode — unprocessed mic but a quiet speaker; false = default mode —
  /// normal speaker loudness (wiki/decisions/d014-looper-m5a.md).
  static set rawInput(bool raw) =>
      bindings.ps_engine_set_raw_input(raw ? 1 : 0);

  /// Requested I/O buffer size in frames for the next [start]; 0 = default.
  static set periodFrames(int frames) =>
      bindings.ps_engine_set_period_frames(frames);

  /// Buffer sizes the OS actually granted, or null when stopped.
  static ({
    int playbackPeriod,
    int playbackPeriods,
    int capturePeriod,
    int capturePeriods,
    int sampleRate,
  })?
  get bufferInfo {
    final p = calloc<ffi.Int32>(5);
    try {
      if (bindings.ps_engine_buffer_info(p) == 0) return null;
      return (
        playbackPeriod: p[0],
        playbackPeriods: p[1],
        capturePeriod: p[2],
        capturePeriods: p[3],
        sampleRate: p[4],
      );
    } finally {
      calloc.free(p);
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
  static void setTone({
    required double frequencyHz,
    required double amplitude,
  }) => bindings.ps_tone_set(frequencyHz, amplitude);

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
        buffer,
        frames,
        channels,
        sampleRate,
        frequencyHz,
        amplitude,
      );
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
      _check(
        bindings.ps_recorder_begin(path.cast(), sampleRate),
        'could not start recording to $wavPath',
      );
    } finally {
      calloc.free(path);
    }
  }

  /// Starts a take after a count-in (M5b, wiki/decisions/d017-tempo-everywhere.md):
  /// the metronome ([Metronome.setGrid]) clicks [countInFrames], and the
  /// take starts on exactly the frame after. With [clickAfter] the click
  /// keeps going while recording (headphones).
  static void beginRecordingCounted(
    String wavPath, {
    required int countInFrames,
    bool clickAfter = false,
    int sampleRate = 48000,
  }) {
    final path = wavPath.toNativeUtf8();
    try {
      _check(
        bindings.ps_recorder_begin_counted(
          path.cast(),
          sampleRate,
          countInFrames,
          clickAfter ? 1 : 0,
        ),
        'could not start recording to $wavPath',
      );
    } finally {
      calloc.free(path);
    }
  }

  /// Finishes the take and writes its peaks file to [peaksPath] (if given).
  static void endRecording({String? peaksPath}) {
    final path = (peaksPath ?? '').toNativeUtf8();
    try {
      _check(
        bindings.ps_recorder_end(path.cast()),
        'could not finish the take',
      );
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

  /// Replaces the edit list with [clips] over the open take's recording —
  /// or, with [source], over another mono float WAV such as a transposed
  /// render of it (M4). Empty = the whole source. Returns the timeline
  /// length; throws if [source] can't be opened.
  static int setClips(List<PlayClip> clips, {String? source}) {
    final c = _NativeClips(clips);
    final path = (source ?? '').toNativeUtf8();
    try {
      final len = bindings.ps_player_set_source_clips_fx(
        path.cast(),
        c.starts,
        c.ends,
        c.gains,
        c.fades,
        c.reverse,
        c.n,
      );
      if (len < 0) {
        throw PocketAudioException(len, 'could not open $source for playback');
      }
      return len;
    } finally {
      c.free();
      calloc.free(path);
    }
  }

  /// Nearest zero crossing in the open take within ±[radius] frames.
  static int zeroCrossing(int sourceFrame, {int radius = 240}) =>
      bindings.ps_player_zero_crossing(sourceFrame, radius);

  /// A–B loop (end exclusive); `end <= start` turns it off.
  static void setLoop(int start, int end) =>
      bindings.ps_player_set_loop(start, end);
  static void clearLoop() => bindings.ps_player_set_loop(0, 0);
  static ({int start, int end})? get loop {
    final s = bindings.ps_player_loop_start(),
        e = bindings.ps_player_loop_end();
    return e > s ? (start: s, end: e) : null;
  }

  /// Tape-style scrubbing: between [beginScrub] and [endScrub] the playhead
  /// chases [scrubTarget] (speed and pitch follow it), or moves at [shuttle]
  /// × real time when that is non-zero.
  static void beginScrub() => bindings.ps_player_begin_scrub();
  static set scrubTarget(double frame) =>
      bindings.ps_player_set_scrub_target(frame);
  static set shuttle(double speed) => bindings.ps_player_set_shuttle(speed);
  static void endScrub() => bindings.ps_player_end_scrub();
  static bool get isScrubbing => bindings.ps_player_is_scrubbing() != 0;

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
      _check(
        bindings.ps_peaks_build(w.cast(), p.cast()),
        'could not build peaks for $wavPath',
      );
    } finally {
      calloc.free(w);
      calloc.free(p);
    }
  }

  // ---- Latency probe (M2 gate) ----

  /// Starts chirping every [intervalMs] and measuring the round trip. Needs
  /// the engine running with input.
  static void startLatencyProbe({int intervalMs = 500}) =>
      bindings.ps_latency_start(intervalMs);
  static void stopLatencyProbe() => bindings.ps_latency_stop();
  static bool get latencyProbeRunning => bindings.ps_latency_is_running() != 0;
  static int get latencyCount => bindings.ps_latency_count();
  static int get latencyMissed => bindings.ps_latency_missed();
  static bool get latencyInputOverflow =>
      bindings.ps_latency_input_overflow() != 0;

  /// Round trips in milliseconds, in measurement order.
  static Float32List latencyResults(int first, int max) {
    if (max <= 0) return Float32List(0);
    final buffer = calloc<ffi.Float>(max);
    try {
      final n = bindings.ps_latency_copy_ms(buffer, first, max);
      return Float32List.fromList(buffer.asTypedList(n));
    } finally {
      calloc.free(buffer);
    }
  }

  /// OS-reported latency of the current route in seconds, or null where the
  /// OS does not report it.
  static ({double input, double output, double ioBuffer})? get reportedLatency {
    final p = calloc<ffi.Double>(3);
    try {
      if (bindings.ps_latency_reported(p, p + 1, p + 2) == 0) return null;
      return (input: p[0], output: p[1], ioBuffer: p[2]);
    } finally {
      calloc.free(p);
    }
  }

  /// Tests: runs the probe against a simulated room. Engine must be stopped.
  static void simulateLatency({
    required int delayFrames,
    required int seconds,
    double echoGain = 0.3,
    double noise = 0.01,
  }) => bindings.ps_latency_simulate(delayFrames, seconds, echoGain, noise);

  // ---- DSP processor (M4) ----

  /// Starts rendering frames [start, end) of [input] into [output],
  /// transposed by [semitones] (fractional = cents) at [tempo] speed, then
  /// varispeed by [speed] (tape-style, pitch moves with it; M7).
  /// Cancels any running render. Returns the job id.
  static int startRender({
    required String input,
    required int start,
    required int end,
    required String output,
    double semitones = 0,
    double tempo = 1,
    bool formant = false,
    double speed = 1,
  }) {
    final i = input.toNativeUtf8(), o = output.toNativeUtf8();
    try {
      return bindings.ps_render_start_ex(
        i.cast(),
        start,
        end,
        o.cast(),
        semitones,
        tempo,
        formant ? 1 : 0,
        speed,
      );
    } finally {
      calloc.free(i);
      calloc.free(o);
    }
  }

  static void cancelRender() => bindings.ps_render_cancel();
  static int get renderJob => bindings.ps_render_job();
  static RenderState get renderState =>
      RenderState.values[bindings.ps_render_state()];
  static double get renderProgress => bindings.ps_render_progress();

  /// Current output route name, e.g. "Speaker" (calibration is per route).
  static String get outputRoute =>
      bindings.ps_output_route().cast<Utf8>().toDartString();

  // ---- Layers (M6) ----

  /// Opens an empty stack in the player (closes any take).
  static void openStack() => bindings.ps_player_open_stack();

  /// Sets the stack's layers: each plays [StackTrack.clips] of
  /// [StackTrack.path] from [StackTrack.offset]. Returns the stack length.
  static int setStack(List<StackTrack> tracks) {
    final n = tracks.length;
    final paths = calloc<ffi.Pointer<ffi.Char>>(math.max(1, n));
    final offsets = calloc<ffi.Int64>(math.max(1, n));
    final counts = calloc<ffi.Int32>(math.max(1, n));
    final c = _NativeClips([for (final t in tracks) ...t.clips]);
    try {
      for (var k = 0; k < n; k++) {
        paths[k] = tracks[k].path.toNativeUtf8().cast();
        offsets[k] = tracks[k].offset;
        counts[k] = tracks[k].clips.length;
      }
      final len = bindings.ps_player_set_stack_fx(
        n,
        paths.cast(),
        offsets,
        counts,
        c.starts,
        c.ends,
        c.gains,
        c.fades,
        c.reverse,
      );
      if (len < 0) {
        throw PocketAudioException(len, 'could not open a layer for playback');
      }
      return len;
    } finally {
      for (var k = 0; k < n; k++) {
        calloc.free(paths[k]);
      }
      calloc.free(paths);
      calloc.free(offsets);
      calloc.free(counts);
      c.free();
    }
  }

  /// Volume of layer [track] (mute/solo/volume); smoothed over 5 ms.
  static void setTrackGain(int track, double gain) =>
      bindings.ps_player_set_track_gain(track, gain);

  /// Mixes the open stack at the current volumes into a mono float WAV.
  static void bounceMix(String path) {
    final p = path.toNativeUtf8();
    try {
      if (bindings.ps_player_bounce(p.cast()) != bindings.PS_OK) {
        throw PocketAudioException(bindings.PS_ERROR_FILE, 'bounce failed');
      }
    } finally {
      calloc.free(p);
    }
  }

  // ---- Sampling tools (M7) ----

  /// Renders [clips] of [source] (empty = all of it) into a mono WAV at
  /// [output] at [sampleRate] (48000 or 44100) and [bits]. [loopFrames] > 0
  /// exports the first [loopFrames] as a seamless loop (see ps_export_wav).
  /// Blocking: call from a background isolate. Throws on failure.
  static void exportWav({
    required String source,
    required List<PlayClip> clips,
    required String output,
    int sampleRate = 48000,
    ExportBits bits = ExportBits.pcm24,
    int loopFrames = 0,
  }) {
    final c = _NativeClips(clips);
    final s = source.toNativeUtf8(), o = output.toNativeUtf8();
    try {
      final r = bindings.ps_export_wav(
        s.cast(),
        c.starts,
        c.ends,
        c.gains,
        c.fades,
        c.reverse,
        c.n,
        o.cast(),
        sampleRate,
        bits.bits,
        loopFrames,
      );
      if (r != bindings.PS_OK) {
        throw PocketAudioException(r, 'could not export $output');
      }
    } finally {
      c.free();
      calloc.free(s);
      calloc.free(o);
    }
  }

  /// Detects the tempo of [clips] of [source] as they play (M5b): BPM in
  /// [minBpm]–[maxBpm], the frame of the first downbeat (on the clips'
  /// timeline) and a confidence 0..1; null if no beat was found. Analyses at
  /// most [maxFrames] (0 = all). Blocking: call from a background isolate.
  static ({double bpm, double firstBeat, double confidence})? detectTempo({
    required String source,
    required List<PlayClip> clips,
    double minBpm = 60,
    double maxBpm = 200,
    int beatsPerBar = 4,
    int maxFrames = 90 * 48000,
  }) {
    final c = _NativeClips(clips);
    final s = source.toNativeUtf8();
    final out = calloc<ffi.Double>(3);
    try {
      final ok = bindings.ps_detect_tempo(
        s.cast(),
        c.starts,
        c.ends,
        c.gains,
        c.fades,
        c.reverse,
        c.n,
        minBpm,
        maxBpm,
        beatsPerBar,
        maxFrames,
        out,
      );
      if (ok == 0) return null;
      return (bpm: out[0], firstBeat: out[1], confidence: out[2]);
    } finally {
      c.free();
      calloc.free(s);
      calloc.free(out);
    }
  }

  /// Largest absolute sample in [ranges] of the mono float WAV at [path].
  /// Blocking (reads the audio): call from a background isolate for long
  /// ranges. Throws if the file can't be read.
  static double peak(String path, List<({int start, int end})> ranges) {
    final n = ranges.length;
    final s = calloc<ffi.Int64>(math.max(1, n));
    final e = calloc<ffi.Int64>(math.max(1, n));
    final p = path.toNativeUtf8();
    try {
      for (var i = 0; i < n; i++) {
        s[i] = ranges[i].start;
        e[i] = ranges[i].end;
      }
      final v = bindings.ps_peak(p.cast(), s, e, n);
      if (v < 0) {
        throw PocketAudioException(bindings.PS_ERROR_FILE, 'cannot read $path');
      }
      return v;
    } finally {
      calloc.free(s);
      calloc.free(e);
      calloc.free(p);
    }
  }

  /// Player position when the current take's first frame was recorded
  /// (-2 = not yet); lines up a layer recorded over a stack.
  static int get recorderStartStamp => bindings.ps_recorder_start_stamp();

  /// Tests: one full audio callback (recorder, player, looper, probe) on
  /// mono [input], without a device. Returns the mono output.
  static Float32List processEngineOffline(Float32List input) {
    final n = input.length;
    final i = calloc<ffi.Float>(n), o = calloc<ffi.Float>(n);
    try {
      i.asTypedList(n).setAll(0, input);
      bindings.ps_engine_process_offline(i, o, n, 1);
      return Float32List.fromList(o.asTypedList(n));
    } finally {
      calloc.free(i);
      calloc.free(o);
    }
  }
}

/// One layer of a stack: clips (in [path]'s frames) placed at [offset].
class StackTrack {
  const StackTrack(this.path, this.offset, this.clips);

  final String path;
  final int offset;
  final List<PlayClip> clips;
}

/// State of the latest render (matches PS_RENDER_*).
enum RenderState { idle, running, done, failed, cancelled }

/// Loop pedal state (matches PS_LOOPER_*).
enum LooperState {
  idle,
  recording,
  closing,
  playing,
  overdubbing,
  stopped,

  /// Overdub waiting for the loop start.
  armed,

  /// Tempo sync: counting in before the first take (M5b).
  countIn,
}

/// Metronome in the audio engine (M5b, wiki/decisions/d017-tempo-everywhere.md):
/// count-in before a take and a click that follows playback.
abstract final class Metronome {
  /// Beat length in frames (0 = off) and beats per bar.
  static void setGrid(double beatFrames, int beatsPerBar) =>
      bindings.ps_metronome_set_grid(beatFrames, beatsPerBar);

  /// Click with playback; musical time = player position − [downbeat]
  /// (display frames).
  static void follow(bool on, {double downbeat = 0}) =>
      bindings.ps_metronome_follow(on ? 1 : 0, downbeat);

  /// Musical frame of the count-in/recording clock (negative while
  /// counting in), or null when not counting.
  static int? get musical {
    final m = bindings.ps_metronome_musical();
    return m == -0x8000000000000000 ? null : m;
  }

  /// The click's sample at musical [frame] (tests).
  static double click(double frame, double beatFrames, int beatsPerBar) =>
      bindings.ps_metronome_click(frame, beatFrames, beatsPerBar);
}

/// The loop pedal in the audio engine (wiki/decisions/d014-looper-m5a.md).
/// Needs the engine running with input; commands apply on the next callback.
abstract final class Looper {
  static void enable() => bindings.ps_looper_enable(1);
  static void disable() => bindings.ps_looper_enable(0);
  static bool get enabled => bindings.ps_looper_enabled() != 0;

  /// Main button: record → close loop → arm an overdub (records exactly one
  /// pass from the loop start) → pressing while armed/recording cancels.
  static void press() => bindings.ps_looper_press();
  static void stop() => bindings.ps_looper_stop();
  static void play() => bindings.ps_looper_play();
  static void clear() => bindings.ps_looper_clear();
  static void undo() => bindings.ps_looper_undo();
  static void redo() => bindings.ps_looper_redo();

  /// Removes overdub layer [layer] (≥ 1) after a 5 ms fade; layers above
  /// it move down one index. Not undoable.
  static void deleteLayer(int layer) => bindings.ps_looper_delete_layer(layer);

  /// Calibrated round trip in frames; overdubs are shifted back by it.
  static set latencyFrames(int frames) =>
      bindings.ps_looper_set_latency(frames);

  /// Effective gain of layer [layer] (0 = first take) after mute/solo/volume.
  static void setLayerGain(int layer, double gain) =>
      bindings.ps_looper_set_layer_gain(layer, gain);

  static LooperState get state =>
      LooperState.values[bindings.ps_looper_state()];
  static int get length => bindings.ps_looper_length();
  static int get position => bindings.ps_looper_position();
  static int get layers => bindings.ps_looper_layers();
  static int get redoable => bindings.ps_looper_redoable();
  static bool get starved => bindings.ps_looper_starved() != 0;
  static double takeInputPeak() => bindings.ps_looper_take_input_peak();
  static double takeOutputPeak() => bindings.ps_looper_take_output_peak();

  /// Mic gain for loop recordings (linear).
  static set inputGain(double g) => bindings.ps_looper_set_input_gain(g);

  /// Loop playback volume (linear; playback only, soft-limited).
  static set outputGain(double g) => bindings.ps_looper_set_output_gain(g);
  static bool get clipped => bindings.ps_looper_clipped() != 0;
  static void resetClip() => bindings.ps_looper_reset_clip();

  /// Mixes the audible layers × [passes] into a mono float WAV at [path].
  static void bounce(String path, {int passes = 1}) {
    final p = path.toNativeUtf8();
    try {
      if (bindings.ps_looper_bounce(p.cast(), passes) != bindings.PS_OK) {
        throw PocketAudioException(bindings.PS_ERROR_FILE, 'bounce failed');
      }
    } finally {
      calloc.free(p);
    }
  }

  /// Tests: runs the looper's audio-thread code on [input] (mono) without a
  /// device and returns its mono output.
  static Float32List processOffline(Float32List input) {
    final n = input.length;
    final i = calloc<ffi.Float>(n), o = calloc<ffi.Float>(n);
    try {
      i.asTypedList(n).setAll(0, input);
      bindings.ps_looper_process_offline(i, o, n, 1);
      return Float32List.fromList(o.asTypedList(n));
    } finally {
      calloc.free(i);
      calloc.free(o);
    }
  }

  /// Tests: prepares layer buffers now instead of waiting for the service
  /// thread.
  static void service() => bindings.ps_looper_service();

  /// Tempo sync (M5b): [beatFrames] 0 = free loops. Taken when Record is
  /// pressed.
  static void setSync(double beatFrames, int beatsPerBar, int countInBeats) =>
      bindings.ps_looper_set_sync(beatFrames, beatsPerBar, countInBeats);

  /// Click while recording/playing a synced loop.
  static set click(bool on) => bindings.ps_looper_set_click(on ? 1 : 0);

  /// Feedback mode: every layer fades by this many dB per pass (0 = off).
  static set feedbackDb(double db) => bindings.ps_looper_set_feedback(db);

  /// Musical frame being heard (negative during a count-in).
  static int get beatPosition => bindings.ps_looper_beat_position();
}
