// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Tempo detection (M5b, wiki/features/beat-grid.md): finds the BPM and beat
// positions of music, so a sample's beat grid can be set from its audio.
//
// 1. Onset envelope: log-magnitude spectral flux (1024-point Hann FFT, hop
//    512 = 10.7 ms), minus its local mean, half-wave rectified.
// 2. Tempo: autocorrelation of the envelope, scored at each candidate
//    period together with its 2× and 4× multiples (a steady beat repeats),
//    weighted by a broad preference around 120 BPM (perceived tempos cluster
//    there; this settles most half/double-time ambiguity). Refined to a
//    fraction of a hop.
// 3. Phase: the beat offset whose comb of beats lands on the most onset
//    energy. The downbeat is the beat of the bar with the most energy.
// Offline; runs on the calling thread.

#ifndef PS_TEMPO_DETECT_H
#define PS_TEMPO_DETECT_H

#include <cstdint>
#include <vector>

namespace ps {

struct TempoResult {
  double bpm = 0;         // 0 = nothing found
  double firstBeat = 0;   // frame of the first beat ≥ 0 (a downbeat)
  double confidence = 0;  // 0..1: how much the best tempo stands out
};

// mono: 48 kHz audio. Tempos are searched in [minBpm, maxBpm].
TempoResult detectTempo(const float* mono, int64_t frames, double minBpm,
                        double maxBpm, int32_t beatsPerBar);

}  // namespace ps

#endif  // PS_TEMPO_DETECT_H
