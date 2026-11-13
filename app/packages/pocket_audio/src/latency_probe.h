// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Round-trip latency probe (wiki/concepts/audio-latency.md,
// wiki/decisions/d008-latency-gate-route.md, wiki/concepts/
// latency-compensation.md).
//
// Audio thread: adds a short windowed chirp to the output every interval and
// copies the raw mic input into a lock-free ring. Both share one frame
// counter, so "input frame k" and "output frame k" belong to the same
// callback. Analysis thread: for each chirp emitted at output frame c, finds
// the chirp in the input by cross-correlation; round trip = peak - c frames.
// Everything in between (buffers, converters, DAC, air, ADC) is included.

#ifndef PS_LATENCY_PROBE_H
#define PS_LATENCY_PROBE_H

#include <array>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

#include "ring_buffer.h"

namespace ps {

class LatencyProbe {
 public:
  static constexpr uint32_t kChirpFrames = 240;    // 5 ms at 48 kHz
  static constexpr uint32_t kMaxLatencyFrames = 19200;  // 400 ms search
  static constexpr size_t kMaxClicks = 8192;

  LatencyProbe();
  ~LatencyProbe();

  // ---- audio thread ----
  void process(const float* in, float* out, uint32_t frames,
               uint32_t outChannels);

  // ---- control ----
  // Starts emitting a chirp every intervalFrames (>= kMaxLatencyFrames +
  // kChirpFrames) and clears previous results.
  void start(uint32_t sampleRate, uint32_t intervalFrames);
  void stop();  // keeps the results
  bool active() const { return active_.load(); }

  // Results (any thread).
  int32_t count();                 // detected chirps
  int32_t missed();                // chirps not found (too quiet/noisy)
  bool inputOverflow() const { return overflow_.load(); }
  // Input samples waiting for the analysis thread (tests use it to pace).
  size_t inputBacklog() const { return input_.available(); }
  // Round trips in milliseconds, in emission order.
  int32_t copyResults(float* outMs, int32_t first, int32_t max);

  const std::array<float, kChirpFrames>& chirp() const { return chirp_; }

 private:
  void analysisLoop();
  void analyse(int64_t clickFrame);

  std::array<float, kChirpFrames> chirp_;
  SpscRing input_;

  // Audio-thread state.
  int64_t frame_ = 0;
  int64_t nextClick_ = 0;
  uint32_t interval_ = 24000;

  // Emitted chirp start frames: written by the audio thread, read by the
  // analysis thread (single producer / single consumer).
  std::array<int64_t, kMaxClicks> clicks_{};
  std::atomic<size_t> clickCount_{0};

  std::atomic<bool> active_{false};
  std::atomic<int32_t> inProcess_{0};
  std::atomic<bool> overflow_{false};
  std::atomic<bool> stopAnalysis_{false};
  std::thread analysis_;

  // Analysis-thread state.
  std::vector<float> history_;  // input samples from absolute frame base_
  int64_t base_ = 0;
  size_t analysed_ = 0;
  uint32_t sampleRate_ = 48000;

  std::mutex resultsMutex_;
  std::vector<float> resultsMs_;
  int32_t missed_ = 0;

  std::mutex controlMutex_;
};

}  // namespace ps

#endif  // PS_LATENCY_PROBE_H
