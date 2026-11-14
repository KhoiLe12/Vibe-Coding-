// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

#include "recorder.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>

#include "pocket_audio.h"

namespace ps {
namespace {

// ~10.9 s at 48 kHz: room for the writer thread to stall on slow storage.
constexpr size_t kRingCapacity = size_t{1} << 19;
constexpr uint32_t kScratchFrames = 4096;
constexpr size_t kDrainChunk = 16384;
// One-pole gain smoothing, ~5 ms at 48 kHz, so gain moves never click.
constexpr float kGainCoef = 0.0042f;

void atomicMax(std::atomic<float>& a, float v) {
  float cur = a.load(std::memory_order_relaxed);
  while (v > cur &&
         !a.compare_exchange_weak(cur, v, std::memory_order_relaxed)) {
  }
}

void put32(std::FILE* f, uint32_t v) {
  const uint8_t b[4] = {static_cast<uint8_t>(v), static_cast<uint8_t>(v >> 8),
                        static_cast<uint8_t>(v >> 16),
                        static_cast<uint8_t>(v >> 24)};
  std::fwrite(b, 1, 4, f);
}

}  // namespace

Recorder::Recorder() : ring_(kRingCapacity), scratch_(kScratchFrames) {}

Recorder::~Recorder() { end(nullptr); }

void Recorder::process(const float* in, uint32_t frames, int64_t stamp) {
  const float target = targetGain_.load(std::memory_order_relaxed);
  inProcess_.fetch_add(1);
  bool writing = active_.load() && !paused_.load(std::memory_order_relaxed);
  // Count-in: hold, or skip to the frame where the take starts.
  uint32_t skip = 0;
  if (writing) {
    const int64_t h = hold_.load(std::memory_order_relaxed);
    if (h == -1) {
      writing = false;
    } else if (h > 0) {
      skip = static_cast<uint32_t>(std::min<int64_t>(h, frames));
      hold_.store(h - skip, std::memory_order_relaxed);
      writing = skip < frames;
    }
  }
  if (writing && startStamp_.load(std::memory_order_relaxed) == -2) {
    startStamp_.store(stamp < 0 ? stamp : stamp + skip);  // first frame
  }

  float peak = 0.0f;
  bool clip = false;
  while (frames > 0) {
    const uint32_t n = std::min(frames, kScratchFrames);
    float* out = scratch_.data();
    for (uint32_t i = 0; i < n; ++i) {
      gain_ += (target - gain_) * kGainCoef;
      // Snap once within 0.01% (a 0.001 dB step, inaudible). Without this the
      // float stalls a few ulps away (the per-sample step rounds to zero),
      // and unity gain would never be bit-exact again.
      if (std::fabs(target - gain_) < 1e-4f * std::fabs(target) + 1e-7f) {
        gain_ = target;
      }
      const float s = in[i] * gain_;
      out[i] = s;
      const float a = std::fabs(s);
      peak = std::max(peak, a);
      clip = clip || a >= 1.0f;
    }
    if (writing && skip < n) {
      const size_t written = ring_.write(out + skip, n - skip);
      if (written < n - skip) {
        dropped_.fetch_add(static_cast<int64_t>(n - skip - written));
      }
    }
    skip = skip > n ? skip - n : 0;
    in += n;
    frames -= n;
  }
  inProcess_.fetch_sub(1);

  atomicMax(level_, peak);
  if (clip) clipped_.store(true, std::memory_order_relaxed);
}

int32_t Recorder::begin(const char* wavPath, uint32_t sampleRate,
                        bool held) {
  std::lock_guard<std::mutex> lock(controlMutex_);
  if (active_.load()) return PS_ERROR_ALREADY_RUNNING;
  if (!wav_.open(wavPath, sampleRate)) return PS_ERROR_FILE;

  sampleRate_ = sampleRate;
  ring_.reset();
  framesWritten_.store(0);
  dropped_.store(0);
  startStamp_.store(-2);  // set by the first callback that writes
  writeError_.store(false);
  paused_.store(false);
  hold_.store(held ? -1 : 0);
  {
    std::lock_guard<std::mutex> peaksLock(peaksMutex_);
    peaks_.clear();
  }
  blockFill_ = 0;
  framesAtLastHeader_ = 0;
  stopWriter_.store(false);
  writer_ = std::thread(&Recorder::writerLoop, this);
  active_.store(true);
  return PS_OK;
}

int32_t Recorder::end(const char* peaksPath) {
  std::lock_guard<std::mutex> lock(controlMutex_);
  if (!writer_.joinable()) return PS_ERROR_NOT_RECORDING;

  // Stop the audio thread from writing, and wait out a process() in flight.
  active_.store(false);
  while (inProcess_.load() != 0) std::this_thread::yield();

  stopWriter_.store(true);
  writer_.join();  // the writer drains everything left before exiting

  std::vector<float> peaksCopy;
  {
    std::lock_guard<std::mutex> peaksLock(peaksMutex_);
    if (blockFill_ > 0) {
      peaks_.push_back(blockMin_);
      peaks_.push_back(blockMax_);
      blockFill_ = 0;
    }
    peaksCopy = peaks_;
  }
  bool ok = wav_.close() && !writeError_.load();
  if (peaksPath && peaksPath[0] != '\0') {
    ok = writePeaksFile(peaksPath, kPeakBlock, peaksCopy) && ok;
  }
  return ok ? PS_OK : PS_ERROR_FILE;
}

void Recorder::writerLoop() {
  std::vector<float> scratch(kDrainChunk);
  while (!stopWriter_.load()) {
    drainOnce(scratch);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  drainOnce(scratch);  // whatever arrived before end()
}

void Recorder::drainOnce(std::vector<float>& scratch) {
  size_t n;
  while ((n = ring_.read(scratch.data(), scratch.size())) > 0) {
    if (!writeError_.load()) {
      if (!wav_.write(scratch.data(), n)) writeError_.store(true);
    }
    if (writeError_.load()) continue;  // keep draining so the ring never fills

    {
      std::lock_guard<std::mutex> lock(peaksMutex_);
      for (size_t i = 0; i < n; ++i) {
        const float s = scratch[i];
        if (blockFill_ == 0) {
          blockMin_ = blockMax_ = s;
        } else {
          blockMin_ = std::min(blockMin_, s);
          blockMax_ = std::max(blockMax_, s);
        }
        if (++blockFill_ == kPeakBlock) {
          peaks_.push_back(blockMin_);
          peaks_.push_back(blockMax_);
          blockFill_ = 0;
        }
      }
    }
    framesWritten_.store(static_cast<int64_t>(wav_.frames()));
  }
  if (wav_.frames() - framesAtLastHeader_ >= sampleRate_) {
    if (!wav_.updateHeader()) writeError_.store(true);
    framesAtLastHeader_ = wav_.frames();
  }
}

int32_t Recorder::copyPeaks(float* out, int32_t firstBlock, int32_t maxBlocks) {
  std::lock_guard<std::mutex> lock(peaksMutex_);
  const int32_t total = static_cast<int32_t>(peaks_.size() / 2);
  if (firstBlock < 0 || firstBlock >= total || maxBlocks <= 0) return 0;
  const int32_t n = std::min(maxBlocks, total - firstBlock);
  std::copy_n(peaks_.data() + 2 * firstBlock, 2 * n, out);
  return n;
}

int32_t Recorder::peakBlockCount() {
  std::lock_guard<std::mutex> lock(peaksMutex_);
  return static_cast<int32_t>(peaks_.size() / 2);
}

bool writePeaksFile(const char* path, uint32_t blockSize,
                    const std::vector<float>& minmax) {
  std::FILE* f = std::fopen(path, "wb");
  if (!f) return false;
  std::fwrite("PSPK", 1, 4, f);
  put32(f, 1);
  put32(f, blockSize);
  put32(f, static_cast<uint32_t>(minmax.size() / 2));
  const bool wrote =
      std::fwrite(minmax.data(), sizeof(float), minmax.size(), f) ==
      minmax.size();
  return (std::fclose(f) == 0) && wrote;
}

}  // namespace ps
