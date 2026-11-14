// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Sample export (M7, wiki/features/sampling-tools.md, wiki/decisions/
// d016-sampling-tools.md): renders an edit list (clips with gains, fades and
// reverse, over a recording or a pitch/tempo render) into a WAV for DAWs and
// samplers — 16/24-bit PCM or 32-bit float, 48 or 44.1 kHz. Runs on the
// calling thread (the app calls it from a background isolate); it plays
// clips exactly as the player does (Player::trackAt), so an export matches
// playback.

#ifndef PS_EXPORTER_H
#define PS_EXPORTER_H

#include <cstdint>
#include <string>
#include <vector>

#include "player.h"

namespace ps {

struct ExportJob {
  std::string source;           // mono float WAV the clips index into
  std::vector<ClipSpec> clips;  // empty = the whole source
  std::string output;
  uint32_t sampleRate = 48000;  // output rate; resampled if it differs
  int32_t bits = 24;            // 16 (TPDF-dithered), 24, or 32 (float)
  // Seamless loop: > 0 exports only the first loopFrames of the clip list
  // and marks the whole file as a loop (smpl chunk). If the list carries at
  // least kSeamFrames more audio after the loop, that audio is crossfaded
  // into the loop's head, so the wrap continues exactly as the recording
  // did. Otherwise both ends get kEdgeFadeFrames fades. Length is never
  // changed.
  int64_t loopFrames = 0;
};

constexpr int64_t kSeamFrames = 480;     // 10 ms at 48 kHz
constexpr int64_t kEdgeFadeFrames = 96;  // 2 ms

// Writes the file (via output + ".tmp", renamed when complete). Returns
// false on bad arguments or a write error.
bool exportWav(const ExportJob& job);

// Largest |sample| in the given ranges of a mono float WAV (0 if none).
// -1 if the file can't be read.
double peakOf(const std::string& path, const int64_t* starts,
              const int64_t* ends, int32_t n);

}  // namespace ps

#endif  // PS_EXPORTER_H
