// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Plays one take (mono float WAV) with random access: the file is mapped
// read-only (mmap) and a prefetch thread keeps the pages around the playhead
// resident, so the audio thread reads any position without blocking in
// practice (wiki/decisions/d011-mapped-player.md).
//
// Modes (audio thread):
// - Normal: rate 1 from the position; optional A–B loop. Loop wraps and
//   seeks while audible are 5 ms crossfades, so they never click
//   (wiki/concepts/crossfades-and-clicks.md).
// - Scrub (tape-style, wiki/decisions/d009-scrub-style.md): the position
//   chases a target set by the finger with smoothed velocity, so speed and
//   pitch follow the finger and it slows to a stop like tape. Shuttle drives
//   the velocity directly (hold-to-rewind / fast-forward).

#ifndef PS_PLAYER_H
#define PS_PLAYER_H

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <thread>

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
  static constexpr uint32_t kFadeFrames = 240;  // 5 ms at 48 kHz

  Player();
  ~Player();

  // ---- audio thread ----
  // Adds the take into interleaved output (same sample on every channel).
  void render(float* out, uint32_t frames, uint32_t channels);

  // ---- control (any non-audio thread) ----
  int32_t open(const char* path);  // PS_* code; paused at frame 0
  void close();
  void setPlaying(bool playing) { playing_.store(playing); }
  bool playing() const { return playing_.load(); }
  bool finished() const { return finished_.load(); }
  // Jumps to frame; crossfades if audible. Takes effect on the next callback.
  int32_t seek(int64_t frame);
  int64_t position() const { return position_.load(); }
  int64_t length() const { return length_.load(); }

  // A–B loop (end exclusive); end <= start clears it.
  void setLoop(int64_t start, int64_t end);
  int64_t loopStart() const { return loopStart_.load(); }
  int64_t loopEnd() const { return loopEnd_.load(); }

  // Scrubbing. While scrubbing, normal play is suspended; endScrub() resumes
  // from wherever the finger ended (playing again if it was playing).
  void beginScrub();
  void setScrubTarget(double frame) { scrubTarget_.store(frame); }
  // Speed in multiples of real time (negative = backwards); 0 = follow the
  // target instead.
  void setShuttle(double speed) { shuttle_.store(speed); }
  void endScrub();
  bool scrubbing() const { return scrubRequested_.load(); }

  void renderForTest(float* out, uint32_t frames, uint32_t channels) {
    render(out, frames, channels);
  }

 private:
  float sampleAt(int64_t i) const;   // 0 outside the take
  float interp(double pos) const;    // 4-point Hermite
  void prefetchLoop();
  void unmapLocked();

  // Mapping (set while the audio thread is excluded).
  const uint8_t* map_ = nullptr;
  size_t mapBytes_ = 0;
  const uint8_t* samples_ = nullptr;  // may be unaligned: read via memcpy
  int64_t frames_ = 0;
  uint32_t sampleRate_ = 48000;

  // Shared state.
  std::atomic<bool> active_{false};
  std::atomic<int32_t> inRender_{0};
  std::atomic<bool> playing_{false};
  std::atomic<bool> finished_{false};
  std::atomic<int64_t> position_{0};
  std::atomic<int64_t> length_{0};
  std::atomic<int64_t> seekRequest_{-1};
  std::atomic<int64_t> loopStart_{0};
  std::atomic<int64_t> loopEnd_{0};
  std::atomic<bool> scrubRequested_{false};
  std::atomic<double> scrubTarget_{0.0};
  std::atomic<double> shuttle_{0.0};
  std::atomic<bool> resumeAfterScrub_{false};

  // Audio-thread state.
  double pos_ = 0.0;        // playhead (frames)
  float playGain_ = 0.0f;   // play/pause ramp
  bool scrubMode_ = false;
  float scrubGain_ = 0.0f;  // fade in/out of scrub mode
  double velocity_ = 0.0;   // scrub, frames per frame
  // Crossfade: the old stream (fromPos_) fades out over kFadeFrames while
  // pos_ fades in.
  bool xfade_ = false;
  double fromPos_ = 0.0;
  float fromGain_ = 0.0f;
  uint32_t xfadeT_ = 0;

  std::thread prefetch_;
  std::atomic<bool> stopPrefetch_{false};
  std::mutex controlMutex_;
};

}  // namespace ps

#endif  // PS_PLAYER_H
