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

// Version string of the audio core, e.g. "0.1.0 (miniaudio 0.11.25)".
PS_EXPORT const char* ps_version(void);

// Opens the default output device (48 kHz, stereo, 32-bit float) and starts
// the real-time callback. Returns PS_OK or a negative error code.
PS_EXPORT int32_t ps_engine_start(void);

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

#ifdef __cplusplus
}
#endif

#endif  // POCKET_AUDIO_H
