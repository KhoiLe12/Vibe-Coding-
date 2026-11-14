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
#include <vector>

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

// One clip of the edit list, placed on the timeline (wiki/decisions/
// d012-chop-model.md).
struct TimelineClip {
  int64_t srcStart, srcEnd;  // frames of the recording, end exclusive
  int64_t tStart;            // where it starts on the timeline
  float gain;
  int64_t half;  // half-width of the crossfade at the join with the previous
                 // clip (0 for the first clip)
};

struct Timeline {
  std::vector<TimelineClip> clips;
  int64_t length = 0;
};

class Player {
 public:
  static constexpr uint32_t kJoinHalfFrames = 240;  // 10 ms crossfade per join
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

  // Replaces the edit list: n clips of [srcStart, srcEnd) with gains; n == 0
  // plays the whole recording. Positions, loops and scrub are in timeline
  // frames. Returns the new timeline length. The caller re-seeks.
  int64_t setClips(const int64_t* srcStarts, const int64_t* srcEnds,
                   const float* gains, int32_t n);

  // Nearest zero crossing of the recording within ±radius of srcFrame (the
  // index of the first sample after the sign change), or srcFrame if none.
  int64_t zeroCrossing(int64_t srcFrame, int32_t radius) const;

  // Timeline frame → recording frame (-1 outside the timeline).
  int64_t sourceFrameAt(int64_t timelineFrame);

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
  float srcAt(int64_t i) const;  // recording frame; 0 outside the take
  // Timeline frame, with equal-power crossfades inside each join.
  float timelineAt(const Timeline* tl, int64_t t) const;
  float interp(const Timeline* tl, double pos) const;  // 4-point Hermite
  Timeline* buildTimeline(const int64_t* s, const int64_t* e, const float* g,
                          int32_t n) const;
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

  std::atomic<Timeline*> timeline_{nullptr};
  std::mutex timelineMutex_;  // swap/delete vs prefetch reads

  std::thread prefetch_;
  std::atomic<bool> stopPrefetch_{false};
  std::mutex controlMutex_;
};

}  // namespace ps

#endif  // PS_PLAYER_H
