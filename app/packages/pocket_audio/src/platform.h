// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Per-OS audio-session and permission glue. iOS owns the AVAudioSession here
// (miniaudio is told to leave it alone) so we can set measurement mode, which
// turns off the OS voice processing (wiki/concepts/
// recording-diverse-material.md). Other OSes: no-ops.

#ifndef PS_PLATFORM_H
#define PS_PLATFORM_H

#include <cstdint>

namespace ps {
namespace platform {

// Configures and activates the audio session for playback only, or for
// play-and-record. With input, `raw` selects measurement mode (unprocessed
// mic, but iOS also turns off the speaker's loudness processing — quiet) vs
// the default mode (normal speaker loudness; no echo cancellation or noise
// suppression either). Returns false if the OS refused.
bool activateSession(bool withInput, bool raw = true);

// Deactivates the session (lets other apps' audio resume).
void deactivateSession();

// Microphone permission as managed by this layer: PS_MIC_* codes.
// OSes where the app shell handles permission (Android) report granted.
int32_t micPermission();

// Shows the OS permission prompt if the answer is not yet known. Async: poll
// micPermission() for the result.
void requestMicPermission();

// Latency the OS reports for the current route, in seconds. Returns false
// where the OS does not report it (everything but iOS for now).
bool reportedLatency(double* input, double* output, double* ioBuffer);

// Short name of the current output route, e.g. "Speaker", "Headphones",
// "BluetoothA2DPOutput" (iOS port type without the prefix). Calibration is
// stored per route. "default" where the OS doesn't say.
const char* outputRoute();

}  // namespace platform
}  // namespace ps

#endif  // PS_PLATFORM_H
