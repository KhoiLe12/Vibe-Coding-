// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Streams one take (mono float WAV) from disk to the output. A reader thread
// keeps a lock-free ring filled; the audio thread only reads the ring.
// Play/pause ramp over ~5 ms so they never click
// (wiki/concepts/crossfades-and-clicks.md). M1 scope: play, pause, seek by
// reopening; scrubbing comes in M2 (wiki/features/playback-and-scrub.md).

#ifndef PS_PLAYER_H
#define PS_PLAYER_H

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>

#include "ring_buffer.h"

namespace ps {

// Reads the layout of a mono 32-bit float WAV. frames is taken from the file
// length when the header is stale (a take cut short by a crash), so nothing
// that reached the disk is lost. Returns false for other formats.
bool probeWav(std::FILE* f, uint32_t* sampleRate, long* dataOffset,
              uint64_t* frames);

// Rebuilds a peaks file from a take, e.g. after a crash cut the take short
// before its peaks were written. Not real-time safe.
bool buildPeaksFromWav(const char* wavPath, const char* peaksPath,
                       uint32_t blockFrames);

class Player {
 public:
  Player();
  ~Player();

  // ---- audio thread ----
  // Adds the take into stereo-or-more interleaved output.
  void render(float* out, uint32_t frames, uint32_t channels);

  // ---- control ----
  int32_t open(const char* path);  // PS_* code; stops any previous take
  void close();
  int32_t seek(int64_t frame);
  void setPlaying(bool playing) { playing_.store(playing); }
  bool playing() const { return playing_.load(); }
  bool finished() const { return finished_.load(); }
  int64_t position() const { return position_.load(); }
  int64_t length() const { return length_.load(); }

  // Offline render for tests: same code path as the audio thread.
  void renderForTest(float* out, uint32_t frames, uint32_t channels) {
    render(out, frames, channels);
  }

 private:
  void startReader(int64_t fromFrame);
  void stopReader();
  void readerLoop();

  SpscRing ring_;
  std::FILE* file_ = nullptr;
  long dataOffset_ = 0;
  std::thread reader_;
  std::atomic<bool> stopReaderFlag_{false};
  std::atomic<bool> readerDone_{false};  // reader hit end of file

  std::atomic<bool> active_{false};  // audio thread may read the ring
  std::atomic<int32_t> inRender_{0};
  std::atomic<bool> playing_{false};
  std::atomic<bool> finished_{false};
  std::atomic<int64_t> position_{0};
  std::atomic<int64_t> length_{0};
  int64_t readPos_ = 0;  // reader thread only
  float gain_ = 0.0f;    // audio thread only (play/pause ramp)

  std::mutex controlMutex_;
};

}  // namespace ps

#endif  // PS_PLAYER_H
