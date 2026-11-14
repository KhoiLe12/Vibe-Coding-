// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Metronome (M5b, wiki/decisions/d017-tempo-everywhere.md): count-in before
// a recording, and a click that follows playback. The click is synthesised
// in the callback (a 30 ms decaying sine: 1.5 kHz on a bar's first beat,
// 1 kHz on the others), so nothing is loaded or allocated.
//
// Musical time is counted in frames from the downbeat: negative during a
// count-in, 0 on the downbeat. A beat lasts `beatFrames` (may be
// fractional).

#ifndef PS_METRONOME_H
#define PS_METRONOME_H

#include <atomic>
#include <cmath>
#include <cstdint>

namespace ps {

class Metronome {
 public:
  static constexpr double kClickSeconds = 0.030;
  static constexpr float kLevel = 0.5f;

  // Click sample at musical frame m (48 kHz). 0 between clicks.
  static float click(double m, double beatFrames, int32_t beatsPerBar) {
    if (beatFrames <= 0) return 0.0f;
    const double b = std::floor(m / beatFrames);
    const double n = m - b * beatFrames;  // frames into the beat
    constexpr double kLen = kClickSeconds * 48000.0;
    if (n >= kLen) return 0.0f;
    const int64_t beat = static_cast<int64_t>(b);
    const int64_t bpb = beatsPerBar > 0 ? beatsPerBar : 4;
    const bool accent = ((beat % bpb) + bpb) % bpb == 0;
    const double f = accent ? 1500.0 : 1000.0;
    const double attack = std::fmin(1.0, n / 48.0);  // 1 ms, no click edge
    const double env = attack * std::exp(-n / (0.006 * 48000.0));
    return static_cast<float>(kLevel * env *
                              std::sin(6.283185307179586 * f * n / 48000.0));
  }

  // ---- control (any thread) ----
  void setGrid(double beatFrames, int32_t beatsPerBar) {
    beatFrames_.store(beatFrames);
    beatsPerBar_.store(beatsPerBar);
  }
  // Click with playback: musical frame = player position − downbeat.
  void setFollow(bool on, double downbeat) {
    downbeat_.store(downbeat);
    follow_.store(on);
  }
  // Next callback: count in for `frames` (then, if clickAfter, keep
  // clicking while recording until stopCounting()).
  void requestCountIn(int64_t frames, bool clickAfter) {
    clickAfter_.store(clickAfter);
    pending_.store(frames < 0 ? 0 : frames);
  }
  void stopCounting() {
    pending_.store(-1);
    counting_.store(false);
  }
  // Musical frame of the count-in / recording clock (negative = counting
  // in), or INT64_MIN when not counting.
  int64_t musical() const {
    return counting_.load() ? musical_.load() : INT64_MIN;
  }

  // ---- audio thread ----
  // A requested count-in, picked up at the start of a callback (or -1).
  int64_t takeCountIn() {
    const int64_t f = pending_.exchange(-1, std::memory_order_relaxed);
    if (f >= 0) {
      mus_ = -f;
      counting_.store(true, std::memory_order_relaxed);
    }
    return f;
  }

  // Adds clicks to `out`. playerPos: the player position at the start of
  // this callback (display frames), used while following playback.
  void render(float* out, uint32_t frames, uint32_t channels,
              bool playerPlaying, int64_t playerPos) {
    const double beat = beatFrames_.load(std::memory_order_relaxed);
    const int32_t bpb = beatsPerBar_.load(std::memory_order_relaxed);
    if (beat <= 0) return;
    if (counting_.load(std::memory_order_relaxed)) {
      const bool after = clickAfter_.load(std::memory_order_relaxed);
      for (uint32_t i = 0; i < frames; ++i) {
        if (mus_ < 0 || after) {
          const float s = click(static_cast<double>(mus_), beat, bpb);
          for (uint32_t c = 0; c < channels; ++c) out[i * channels + c] += s;
        }
        ++mus_;
      }
      musical_.store(mus_, std::memory_order_relaxed);
      return;
    }
    if (follow_.load(std::memory_order_relaxed) && playerPlaying) {
      const double m0 =
          static_cast<double>(playerPos) - downbeat_.load(std::memory_order_relaxed);
      for (uint32_t i = 0; i < frames; ++i) {
        const float s = click(m0 + i, beat, bpb);
        for (uint32_t c = 0; c < channels; ++c) out[i * channels + c] += s;
      }
    }
  }

 private:
  std::atomic<double> beatFrames_{0.0};
  std::atomic<int32_t> beatsPerBar_{4};
  std::atomic<double> downbeat_{0.0};
  std::atomic<bool> follow_{false};
  std::atomic<bool> clickAfter_{false};
  std::atomic<int64_t> pending_{-1};
  std::atomic<bool> counting_{false};
  std::atomic<int64_t> musical_{0};
  int64_t mus_ = 0;  // audio thread
};

}  // namespace ps

#endif  // PS_METRONOME_H
