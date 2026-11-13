// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

#include "latency_probe.h"

#include <algorithm>
#include <chrono>
#include <cmath>

namespace ps {
namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr size_t kInputRing = size_t{1} << 18;  // ~5.5 s at 48 kHz
// Peak must stand this far above the correlation's RMS to count.
constexpr double kMinConfidence = 6.0;

}  // namespace

LatencyProbe::LatencyProbe() : input_(kInputRing) {
  // Linear chirp 1.5 → 7 kHz, Hann window. Sharp autocorrelation peak, and
  // well inside what phone speakers and mics reproduce.
  const double sr = 48000.0, f0 = 1500.0, f1 = 7000.0;
  const double t1 = kChirpFrames / sr;
  for (uint32_t i = 0; i < kChirpFrames; ++i) {
    const double t = i / sr;
    const double phase = 2 * kPi * (f0 * t + (f1 - f0) * t * t / (2 * t1));
    const double w = 0.5 - 0.5 * std::cos(2 * kPi * i / (kChirpFrames - 1));
    chirp_[i] = static_cast<float>(0.5 * w * std::sin(phase));
  }
}

LatencyProbe::~LatencyProbe() { stop(); }

void LatencyProbe::process(const float* in, float* out, uint32_t frames,
                           uint32_t outChannels) {
  inProcess_.fetch_add(1);
  if (!active_.load()) {
    inProcess_.fetch_sub(1);
    return;
  }
  for (uint32_t i = 0; i < frames; ++i) {
    const int64_t f = frame_ + i;
    const int64_t k = f - nextClick_;
    if (k >= 0 && k < kChirpFrames) {
      const float s = chirp_[static_cast<size_t>(k)];
      for (uint32_t c = 0; c < outChannels; ++c) out[i * outChannels + c] += s;
      if (k == kChirpFrames - 1) {
        const size_t n = clickCount_.load(std::memory_order_relaxed);
        if (n < kMaxClicks) {
          clicks_[n] = nextClick_;
          clickCount_.store(n + 1, std::memory_order_release);
          nextClick_ += interval_;
        } else {
          nextClick_ = INT64_MAX;  // full: stop clicking
        }
      }
    }
  }
  if (in != nullptr && input_.write(in, frames) < frames) overflow_.store(true);
  frame_ += frames;
  inProcess_.fetch_sub(1);
}

void LatencyProbe::start(uint32_t sampleRate, uint32_t intervalFrames) {
  std::lock_guard<std::mutex> lock(controlMutex_);
  active_.store(false);
  while (inProcess_.load() != 0) std::this_thread::yield();
  if (analysis_.joinable()) {
    stopAnalysis_.store(true);
    analysis_.join();
  }
  sampleRate_ = sampleRate;
  interval_ = std::max(intervalFrames, kMaxLatencyFrames + kChirpFrames);
  frame_ = 0;
  nextClick_ = sampleRate / 4;  // let the device settle first
  clickCount_.store(0);
  input_.reset();
  overflow_.store(false);
  history_.clear();
  base_ = 0;
  analysed_ = 0;
  {
    std::lock_guard<std::mutex> r(resultsMutex_);
    resultsMs_.clear();
    missed_ = 0;
  }
  stopAnalysis_.store(false);
  analysis_ = std::thread(&LatencyProbe::analysisLoop, this);
  active_.store(true);
}

void LatencyProbe::stop() {
  std::lock_guard<std::mutex> lock(controlMutex_);
  active_.store(false);
  while (inProcess_.load() != 0) std::this_thread::yield();
  if (analysis_.joinable()) {
    stopAnalysis_.store(true);
    analysis_.join();
  }
}

void LatencyProbe::analysisLoop() {
  std::vector<float> chunk(8192);
  for (;;) {
    const bool stopping = stopAnalysis_.load();
    size_t n;
    while ((n = input_.read(chunk.data(), chunk.size())) > 0) {
      history_.insert(history_.end(), chunk.begin(), chunk.begin() + n);
    }
    const size_t clicks = clickCount_.load(std::memory_order_acquire);
    const int64_t have = base_ + static_cast<int64_t>(history_.size());
    while (analysed_ < clicks) {
      const int64_t c = clicks_[analysed_];
      if (c + kMaxLatencyFrames + kChirpFrames > have) break;  // not yet
      analyse(c);
      ++analysed_;
      // Drop input nobody needs any more.
      const int64_t keepFrom = c + kChirpFrames;
      if (keepFrom > base_ + 48000) {
        const size_t drop = static_cast<size_t>(keepFrom - base_);
        history_.erase(history_.begin(), history_.begin() + drop);
        base_ = keepFrom;
      }
    }
    if (stopping) return;
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
}

void LatencyProbe::analyse(int64_t clickFrame) {
  const size_t start = static_cast<size_t>(clickFrame - base_);
  const float* x = history_.data() + start;
  double best = 0.0, sumSq = 0.0;
  int64_t bestLag = -1;
  for (uint32_t lag = 0; lag < kMaxLatencyFrames; ++lag) {
    double r = 0.0;
    for (uint32_t j = 0; j < kChirpFrames; ++j) r += chirp_[j] * x[lag + j];
    sumSq += r * r;
    if (std::fabs(r) > best) {
      best = std::fabs(r);
      bestLag = lag;
    }
  }
  const double rms = std::sqrt(sumSq / kMaxLatencyFrames);
  std::lock_guard<std::mutex> lock(resultsMutex_);
  if (bestLag < 0 || rms <= 0.0 || best / rms < kMinConfidence) {
    ++missed_;
    return;
  }
  resultsMs_.push_back(static_cast<float>(bestLag * 1000.0 / sampleRate_));
}

int32_t LatencyProbe::count() {
  std::lock_guard<std::mutex> lock(resultsMutex_);
  return static_cast<int32_t>(resultsMs_.size());
}

int32_t LatencyProbe::missed() {
  std::lock_guard<std::mutex> lock(resultsMutex_);
  return missed_;
}

int32_t LatencyProbe::copyResults(float* outMs, int32_t first, int32_t max) {
  std::lock_guard<std::mutex> lock(resultsMutex_);
  const int32_t total = static_cast<int32_t>(resultsMs_.size());
  if (first < 0 || first >= total || max <= 0) return 0;
  const int32_t n = std::min(max, total - first);
  std::copy_n(resultsMs_.data() + first, n, outMs);
  return n;
}

}  // namespace ps
