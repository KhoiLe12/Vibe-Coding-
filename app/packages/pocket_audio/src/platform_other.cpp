// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Android and Linux: no audio session to manage here. On Android the app
// shell (Kotlin) asks for RECORD_AUDIO and runs the foreground service.

#include "platform.h"
#include "pocket_audio.h"

namespace ps {
namespace platform {

bool activateSession(bool, bool) { return true; }
void deactivateSession() {}
int32_t micPermission() { return PS_MIC_GRANTED; }
void requestMicPermission() {}
bool reportedLatency(double*, double*, double*) { return false; }
const char* outputRoute() { return "default"; }

}  // namespace platform
}  // namespace ps
