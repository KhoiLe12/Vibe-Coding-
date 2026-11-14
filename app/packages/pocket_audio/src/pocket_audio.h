// Pocket Studio audio core — C API exposed to Dart via dart:ffi.
//
// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Bindings are generated from this header: `dart run ffigen --config ffigen.yaml`.
// See wiki/components/audio-engine.md.

#ifndef POCKET_AUDIO_H
#define POCKET_AUDIO_H

#include <stdint.h>

#if _WIN32
#define PS_EXPORT __declspec(dllexport)
#else
#define PS_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Result codes. Negative values are errors.
#define PS_OK 0
#define PS_ERROR_DEVICE -1
#define PS_ERROR_ALREADY_RUNNING -2
#define PS_ERROR_FILE -3
#define PS_ERROR_NOT_RECORDING -4
#define PS_ERROR_NO_PERMISSION -5

// Microphone permission states.
#define PS_MIC_UNDETERMINED 0
#define PS_MIC_GRANTED 1
#define PS_MIC_DENIED 2

// Version string of the audio core, e.g. "0.1.0 (miniaudio 0.11.25)".
PS_EXPORT const char* ps_version(void);

// Opens the default output device (48 kHz, stereo, 32-bit float) and starts
// the real-time callback. Returns PS_OK or a negative error code.
PS_EXPORT int32_t ps_engine_start(void);

// Like ps_engine_start, but with_input != 0 opens the device full duplex:
// mono 32-bit float microphone input feeding the input stage/recorder, plus
// stereo output. iOS: play-and-record session in measurement mode (no voice
// processing), speaker by default. Android: UNPROCESSED input preset, falling
// back to VOICE_RECOGNITION. Returns PS_ERROR_NO_PERMISSION if the
// microphone permission is not granted (iOS).
PS_EXPORT int32_t ps_engine_start_ex(int32_t with_input);

// Requested I/O buffer (period) size in frames for the next start; 0 = the
// default (10 ms). Smaller = lower latency, more CPU wake-ups.
PS_EXPORT void ps_engine_set_period_frames(int32_t frames);

// iOS, for the next start with input: raw != 0 (default) = measurement mode
// (unprocessed mic, quiet speaker); 0 = default mode (normal speaker
// loudness, light mic processing, no echo cancel). Loop pedal uses 0.
PS_EXPORT void ps_engine_set_raw_input(int32_t raw);

// Buffer sizes actually granted, into out_values[5]: playback period frames,
// playback periods, capture period frames, capture periods, device sample
// rate. Returns 1 while running, else 0.
PS_EXPORT int32_t ps_engine_buffer_info(int32_t* out_values);

// 1 if running with microphone input.
PS_EXPORT int32_t ps_engine_has_input(void);

// Number of OS audio interruptions (calls, Siri, other apps) since launch.
// The engine restarts by itself when an interruption ends.
PS_EXPORT int32_t ps_engine_interruption_count(void);

// Microphone permission (PS_MIC_*). Managed here on iOS; elsewhere reports
// PS_MIC_GRANTED (Android asks in the app shell).
PS_EXPORT int32_t ps_mic_permission(void);

// Shows the OS permission prompt if not yet answered. Poll ps_mic_permission.
PS_EXPORT void ps_mic_request_permission(void);

// Stops the callback and closes the device. Safe to call when not running.
PS_EXPORT void ps_engine_stop(void);

// 1 if the device is running, else 0.
PS_EXPORT int32_t ps_engine_is_running(void);

// Actual device sample rate, or 0 when not running.
PS_EXPORT int32_t ps_engine_sample_rate(void);

// Number of audio callbacks served since start. Lets callers verify that the
// device is really pulling audio.
PS_EXPORT int64_t ps_engine_callback_count(void);

// Sets the test tone. amplitude is linear (0 = silent, 1 = full scale).
// Amplitude changes are ramped on the audio thread (at most full scale per
// 10 ms), so they never click.
// Lock-free; safe to call from any thread at any time.
PS_EXPORT void ps_tone_set(double frequency_hz, float amplitude);

// Renders the tone offline into `out` (interleaved, `channels` per frame)
// without any device. Used by tests to check the generator.
PS_EXPORT void ps_tone_render_offline(float* out, int32_t frames,
                                      int32_t channels, int32_t sample_rate,
                                      double frequency_hz, float amplitude);

// ---- Recorder (M1) -------------------------------------------------------
// Takes are mono 32-bit float WAV (wiki/decisions/d007-recording-format.md).
// The input stage (gain, level meter, clip flag) runs on every input buffer,
// whether or not a take is recording.

// Frames per min/max pair in live and stored peaks (256).
PS_EXPORT int32_t ps_peaks_block_frames(void);

// Feeds mono input through the input stage and, while recording, into the
// take. This is exactly what the device's audio callback calls; tests call it
// directly to record without a microphone. Real-time safe.
PS_EXPORT void ps_input_process(const float* mono, int32_t frames);

// Input gain, linear (1 = unity). Smoothed on the audio thread (~5 ms).
PS_EXPORT void ps_input_set_gain(float linear_gain);

// Highest absolute post-gain sample since the previous call (0..). Resets.
PS_EXPORT float ps_input_take_peak_level(void);

// 1 if any post-gain sample reached full scale since the last reset.
PS_EXPORT int32_t ps_input_clipped(void);
PS_EXPORT void ps_input_reset_clip(void);

// Starts a take: creates the WAV at wav_path and starts the writer thread.
// Does not open any audio device. Returns PS_OK, PS_ERROR_ALREADY_RUNNING
// or PS_ERROR_FILE.
PS_EXPORT int32_t ps_recorder_begin(const char* wav_path, int32_t sample_rate);

// Finishes the take: drains buffered audio, finalizes the WAV and, unless
// peaks_path is NULL/empty, writes the peaks file. Blocks briefly.
// Returns PS_OK, PS_ERROR_NOT_RECORDING or PS_ERROR_FILE.
PS_EXPORT int32_t ps_recorder_end(const char* peaks_path);

// While paused, input is metered but not written; resume appends to the
// same take.
PS_EXPORT void ps_recorder_set_paused(int32_t paused);
PS_EXPORT int32_t ps_recorder_is_paused(void);
PS_EXPORT int32_t ps_recorder_is_recording(void);

// Frames saved to the file so far, and frames lost because the writer fell
// behind (should stay 0).
PS_EXPORT int64_t ps_recorder_frames_written(void);
PS_EXPORT int64_t ps_recorder_dropped_frames(void);

// 1 after a disk error or the 4 GiB WAV limit; the take keeps what was
// already saved.
PS_EXPORT int32_t ps_recorder_write_error(void);

// Live waveform: copies up to max_blocks (min, max) pairs starting at
// first_block into out (2 floats per block). Returns blocks copied.
PS_EXPORT int32_t ps_recorder_copy_peaks(float* out, int32_t first_block,
                                         int32_t max_blocks);
PS_EXPORT int32_t ps_recorder_peak_block_count(void);

// ---- Player (M1/M2) ------------------------------------------------------
// Plays one take from a read-only memory map (random access), mixed into the
// engine output. Play/pause ramp over 5 ms; seeks while audible crossfade
// (no clicks). Takes cut short by a crash play in full: the length comes from
// the file size when the header lags.

// Opens a take (mono 32-bit float WAV), paused at frame 0. Closes any
// previous take. Returns PS_OK or PS_ERROR_FILE.
PS_EXPORT int32_t ps_player_open(const char* wav_path);
PS_EXPORT void ps_player_close(void);
PS_EXPORT void ps_player_set_playing(int32_t playing);
PS_EXPORT int32_t ps_player_is_playing(void);
// 1 once playback reached the end (playing turns 0). Cleared by seek/open.
PS_EXPORT int32_t ps_player_finished(void);
// Jumps to frame on the next callback (crossfades if audible).
PS_EXPORT int32_t ps_player_seek(int64_t frame);
PS_EXPORT int64_t ps_player_position(void);
PS_EXPORT int64_t ps_player_length(void);

// Edit list (M3, wiki/decisions/d012-chop-model.md): count clips, each
// [src_starts[i], src_ends[i]) of the open take with linear gain gains[i]
// (gains may be NULL = 1). count 0 plays the whole recording. Joins are
// 10 ms equal-power crossfades. All player positions, loops and scrubbing are
// in timeline frames. Returns the new timeline length (-1 on bad arguments).
// Fade out playback before calling while audible; then seek.
PS_EXPORT int64_t ps_player_set_clips(const int64_t* src_starts,
                                      const int64_t* src_ends,
                                      const float* gains, int32_t count);

// Like ps_player_set_clips, but the clips index into source_path (a mono
// float WAV, e.g. a transposed render of the take, M4) instead of the
// recording. NULL/"" = the recording. Swaps atomically like an edit. Returns
// the new timeline length, or -1 if the source can't be opened.
PS_EXPORT int64_t ps_player_set_source_clips(const char* source_path,
                                             const int64_t* src_starts,
                                             const int64_t* src_ends,
                                             const float* gains,
                                             int32_t count);

// Nearest zero crossing in the open take's recording within ±radius frames
// of src_frame, or src_frame if there is none (used to snap cuts).
PS_EXPORT int64_t ps_player_zero_crossing(int64_t src_frame, int32_t radius);

// A–B loop, end exclusive. Wraps are 5 ms crossfades with the loop period
// exactly end - start. end <= start (or a loop under 10 ms) turns it off.
PS_EXPORT void ps_player_set_loop(int64_t start, int64_t end);
PS_EXPORT int64_t ps_player_loop_start(void);
PS_EXPORT int64_t ps_player_loop_end(void);

// Tape-style scrubbing (wiki/decisions/d009-scrub-style.md). Between begin
// and end, the playhead chases the target frame with smoothed velocity (speed
// and pitch follow the finger), or moves at the shuttle speed if non-zero
// (multiples of real time; negative = backwards). end_scrub continues from
// where it stopped, playing again if it was playing before.
PS_EXPORT void ps_player_begin_scrub(void);
PS_EXPORT void ps_player_set_scrub_target(double frame);
PS_EXPORT void ps_player_set_shuttle(double speed);
PS_EXPORT void ps_player_end_scrub(void);
PS_EXPORT int32_t ps_player_is_scrubbing(void);

// Runs the player's audio-thread code into out (zeroed first) without a
// device. For tests; do not call while the engine is running.
PS_EXPORT void ps_player_render_offline(float* out, int32_t frames,
                                        int32_t channels);

// Rebuilds a take's peaks file from its WAV (e.g. after a crash). Slow for
// long takes: call off the UI thread. Returns PS_OK or PS_ERROR_FILE.
PS_EXPORT int32_t ps_peaks_build(const char* wav_path, const char* peaks_path);

// ---- DSP processor (M4) --------------------------------------------------
// Offline pitch/time render with Signalsmith Stretch on a worker thread
// (wiki/components/dsp-processor.md). Renders frames [start, end) of a mono
// float WAV into a new mono float WAV of exactly round((end-start)/tempo)
// frames, transposed by semitones (fractional = cents); formant != 0 keeps
// formants (voice). The file appears only when complete. One job at a time:
// starting one cancels the previous.

#define PS_RENDER_IDLE 0
#define PS_RENDER_RUNNING 1
#define PS_RENDER_DONE 2
#define PS_RENDER_FAILED 3
#define PS_RENDER_CANCELLED 4

// Returns the new job's id (> 0), or -1 on bad arguments.
PS_EXPORT int32_t ps_render_start(const char* input, int64_t start,
                                  int64_t end, const char* output,
                                  double semitones, double tempo,
                                  int32_t formant);
PS_EXPORT void ps_render_cancel(void);
// Id, state (PS_RENDER_*) and progress (0..1) of the latest job.
PS_EXPORT int32_t ps_render_job(void);
PS_EXPORT int32_t ps_render_state(void);
PS_EXPORT double ps_render_progress(void);

// ---- Looper (M5a) ---------------------------------------------------------
// Loop pedal in the audio callback (wiki/decisions/d014-looper-m5a.md).
// Needs the engine running with input. Commands are queued lock-free and
// take effect on the next callback.

#define PS_LOOPER_IDLE 0
#define PS_LOOPER_RECORDING 1
#define PS_LOOPER_CLOSING 2
#define PS_LOOPER_PLAYING 3
#define PS_LOOPER_OVERDUBBING 4
#define PS_LOOPER_STOPPED 5
#define PS_LOOPER_ARMED 6

// Allocates (on) or frees (off) the looper; off also clears it.
PS_EXPORT void ps_looper_enable(int32_t on);
PS_EXPORT int32_t ps_looper_enabled(void);
// Main button: Idle→record, Recording→close loop, Playing→Armed (overdub
// starts at the next loop start and records exactly one pass, then adds the
// layer by itself); pressing while Armed/Overdubbing cancels it.
PS_EXPORT void ps_looper_press(void);
PS_EXPORT void ps_looper_stop(void);
PS_EXPORT void ps_looper_play(void);
PS_EXPORT void ps_looper_clear(void);
// Undo/redo the last overdub layer (instant; the base take stays).
PS_EXPORT void ps_looper_undo(void);
PS_EXPORT void ps_looper_redo(void);
// Removes overdub layer i (1 ≤ i < layers; the first take stays) after a
// 5 ms fade-out; layers above it move down one index. Not undoable.
PS_EXPORT void ps_looper_delete_layer(int32_t layer);
// Calibrated round trip in frames; overdubs are shifted back by it.
PS_EXPORT void ps_looper_set_latency(int32_t frames);
// Effective gain of layer i (0 = base take) after mute/solo/volume.
PS_EXPORT void ps_looper_set_layer_gain(int32_t layer, float gain);
PS_EXPORT int32_t ps_looper_state(void);
PS_EXPORT int64_t ps_looper_length(void);    // loop frames (0 = none)
PS_EXPORT int64_t ps_looper_position(void);  // playhead (or recorded frames)
PS_EXPORT int32_t ps_looper_layers(void);    // audible layers incl. base
PS_EXPORT int32_t ps_looper_redoable(void);
// 1 if an overdub couldn't start/continue for lack of a prepared buffer.
PS_EXPORT int32_t ps_looper_starved(void);
PS_EXPORT float ps_looper_take_input_peak(void);
PS_EXPORT float ps_looper_take_output_peak(void);
// Mic gain for loop recordings, and loop playback volume (playback only,
// soft-limited). Linear, smoothed over ~50 ms.
PS_EXPORT void ps_looper_set_input_gain(float gain);
PS_EXPORT void ps_looper_set_output_gain(float gain);
// 1 if the (gained) mic input reached full scale since the last reset.
PS_EXPORT int32_t ps_looper_clipped(void);
PS_EXPORT void ps_looper_reset_clip(void);
// Mixes audible layers × passes into a mono float WAV (Playing/Stopped only).
PS_EXPORT int32_t ps_looper_bounce(const char* path, int32_t passes);
// Tests: run the looper's audio-thread code / service step without a device.
PS_EXPORT void ps_looper_process_offline(const float* in, float* out,
                                         int32_t frames, int32_t channels);
PS_EXPORT void ps_looper_service(void);

// Current output route name (calibration is per route). Valid until the next
// call on the same thread.
PS_EXPORT const char* ps_output_route(void);

// ---- Layers (M6) ----------------------------------------------------------
// A stack plays several takes at once, each at an offset (wiki/features/
// layers.md). Positions, seek, loop and scrub work on the stack's timeline.

// Opens an empty stack in the player (closes any take).
PS_EXPORT void ps_player_open_stack(void);
// Sets the stack: count tracks; track k plays clip_counts[k] clips (in order
// from the flattened starts/ends/gains, NULL gains = 1) of the mono float
// WAV paths[k], from offsets[k] on the timeline; 5 ms fades at each track's
// ends. Returns the stack length, or -1 (bad arguments / unopenable file).
PS_EXPORT int64_t ps_player_set_stack(int32_t count, const char* const* paths,
                                      const int64_t* offsets,
                                      const int32_t* clip_counts,
                                      const int64_t* starts,
                                      const int64_t* ends, const float* gains);
// Volume of track k (mute/solo/volume); smoothed over 5 ms.
PS_EXPORT void ps_player_set_track_gain(int32_t track, float gain);
// Mixes the open stack (or take) at the current volumes into a mono float WAV.
PS_EXPORT int32_t ps_player_bounce(const char* path);
// Player position at the callback that wrote the current take's first
// frame (-2 = not yet, -1 = no player position); lines up a layer recorded
// over a stack: offset = stamp − calibrated round trip.
PS_EXPORT int64_t ps_recorder_start_stamp(void);
// Tests: runs one full audio callback (recorder, player, looper, probe)
// without a device. Do not call while the engine is running.
PS_EXPORT void ps_engine_process_offline(const float* input, float* output,
                                         int32_t frames, int32_t channels);

// ---- Latency probe (M2 go/no-go gate) ------------------------------------
// wiki/decisions/d008-latency-gate-route.md. While running, a 5 ms chirp is
// added to the output every interval and found again in the mic input; each
// detection is one round-trip measurement. Needs the engine running with
// input (ps_engine_start_ex(1)).

// Starts chirping every interval_ms (at least ~405 ms) and clears results.
PS_EXPORT void ps_latency_start(int32_t interval_ms);
// Stops chirping; results stay readable.
PS_EXPORT void ps_latency_stop(void);
PS_EXPORT int32_t ps_latency_is_running(void);
// Detected chirps, and chirps not found (too quiet or noisy).
PS_EXPORT int32_t ps_latency_count(void);
PS_EXPORT int32_t ps_latency_missed(void);
// 1 if the analysis fell behind and input was lost (results unreliable).
PS_EXPORT int32_t ps_latency_input_overflow(void);
// Copies round trips in ms (emission order). Returns how many were copied.
PS_EXPORT int32_t ps_latency_copy_ms(float* out, int32_t first, int32_t max);

// OS-reported latency of the current route, in seconds. Returns 1 if the OS
// reports it (iOS), else 0.
PS_EXPORT int32_t ps_latency_reported(double* input_s, double* output_s,
                                      double* io_buffer_s);

// Tests: runs the probe against a simulated room (echo after delay_frames,
// scaled by echo_gain, plus white noise). Engine must not be running.
// Blocks; results are then readable through the functions above.
PS_EXPORT void ps_latency_simulate(int32_t delay_frames, int32_t seconds,
                                   float echo_gain, float noise_amp);

#ifdef __cplusplus
}
#endif

#endif  // POCKET_AUDIO_H
