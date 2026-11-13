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
// play-and-record. Returns false if the OS refused.
bool activateSession(bool withInput);

// Deactivates the session (lets other apps' audio resume).
void deactivateSession();

// Microphone permission as managed by this layer: PS_MIC_* codes.
// OSes where the app shell handles permission (Android) report granted.
int32_t micPermission();

// Shows the OS permission prompt if the answer is not yet known. Async: poll
// micPermission() for the result.
void requestMicPermission();

}  // namespace platform
}  // namespace ps

#endif  // PS_PLATFORM_H
