// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Input stage + recorder. See wiki/components/audio-engine.md and
// wiki/features/record.md.
//
// Real-time path (audio thread): Recorder::process() applies input gain,
// updates the level meter and clip flag, and — while a take is recording and
// not paused — copies samples into a lock-free ring. Nothing else.
//
// Writer thread: drains the ring into a WavWriter, builds min/max peaks for
// the waveform (wiki/concepts/waveform-rendering.md) and patches the WAV
// header about once a second so a crash loses at most ~1 s.

#ifndef PS_RECORDER_H
#define PS_RECORDER_H

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "ring_buffer.h"
#include "wav_writer.h"

namespace ps {

class Recorder {
 public:
  static constexpr uint32_t kPeakBlock = 256;  // frames per min/max pair

  Recorder();
  ~Recorder();

  // ---- audio thread ----
  // `stamp`: the player position at the start of this callback. The stamp
  // of the callback that writes a take's first frame is kept, so a layer
  // recorded over a stack can be lined up (M6, wiki/features/layers.md).
  void process(const float* mono, uint32_t frames, int64_t stamp = -1);
  int64_t startStamp() const { return startStamp_.load(); }

  // ---- control (any non-audio thread) ----
  // Starts a take: opens the WAV and the writer thread. Returns PS_* code.
  int32_t begin(const char* wavPath, uint32_t sampleRate);
  // Finishes the take: drains, finalizes the WAV, writes the peaks file
  // (skipped when peaksPath is null or empty). Returns PS_* code.
  int32_t end(const char* peaksPath);
  void setPaused(bool paused) { paused_.store(paused); }
  bool paused() const { return paused_.load(); }
  bool recording() const { return active_.load(); }

  void setGain(float linear) { targetGain_.store(linear); }
  float takePeakLevel() { return level_.exchange(0.0f); }
  bool clipped() const { return clipped_.load(); }
  void resetClip() { clipped_.store(false); }

  int64_t framesWritten() const { return framesWritten_.load(); }
  int64_t droppedFrames() const { return dropped_.load(); }
  // True once the take hit an I/O error or the 4 GiB limit; the take keeps
  // what was written before that.
  bool writeError() const { return writeError_.load(); }

  // Copies up to maxBlocks min/max pairs starting at firstBlock into out
  // (2 floats per block). Returns the number of blocks copied.
  int32_t copyPeaks(float* out, int32_t firstBlock, int32_t maxBlocks);
  int32_t peakBlockCount();

 private:
  void writerLoop();
  void drainOnce(std::vector<float>& scratch);

  SpscRing ring_;
  WavWriter wav_;
  std::thread writer_;

  std::atomic<bool> active_{false};
  std::atomic<bool> paused_{false};
  std::atomic<bool> stopWriter_{false};
  std::atomic<int32_t> inProcess_{0};

  std::atomic<float> targetGain_{1.0f};
  float gain_ = 1.0f;  // audio thread only
  std::atomic<float> level_{0.0f};
  std::atomic<bool> clipped_{false};

  std::atomic<int64_t> framesWritten_{0};
  std::atomic<int64_t> startStamp_{-1};
  std::atomic<int64_t> dropped_{0};
  std::atomic<bool> writeError_{false};

  // Peaks: writer thread appends; readers copy under the mutex.
  std::mutex peaksMutex_;
  std::vector<float> peaks_;
  float blockMin_ = 0.0f, blockMax_ = 0.0f;  // writer thread only
  uint32_t blockFill_ = 0;
  uint32_t sampleRate_ = 48000;
  uint64_t framesAtLastHeader_ = 0;

  std::mutex controlMutex_;
  std::vector<float> scratch_;  // process() scratch for gained samples
};

// Peaks file: "PSPK" | u32 version=1 | u32 block size | u32 block count |
// block count × (f32 min, f32 max). Little-endian.
bool writePeaksFile(const char* path, uint32_t blockSize,
                    const std::vector<float>& minmax);

}  // namespace ps

#endif  // PS_RECORDER_H
