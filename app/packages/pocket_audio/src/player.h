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

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <memory>
#include <string>
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

// A mono float WAV mapped read-only. Unmapped when the last owner lets go,
// so a timeline keeps its source alive for as long as the audio thread may
// read it.
struct MappedWav {
  ~MappedWav();
  static std::shared_ptr<MappedWav> open(const char* path);
  float at(int64_t i) const;  // 0 outside the file

  std::string path;
  const uint8_t* map = nullptr;
  size_t bytes = 0;
  const uint8_t* samples = nullptr;  // data starts at byte 58: unaligned
  int64_t frames = 0;
  uint32_t sampleRate = 48000;
};

// Fades of a clip (M7, wiki/decisions/d016-sampling-tools.md), in the
// clip's own frames (timeline order, so independent of reverse): silent
// before inA, fading in to full at inB; full until outA, silent from outB.
// A ramp with B <= A is off. Positions may lie outside the clip — after a
// split, each piece keeps its share of the same curve, so a split never
// changes the sound.
struct Fades {
  double inA = 0, inB = 0, outA = 0, outB = 0;
  bool hasIn() const { return inB > inA; }
  bool hasOut() const { return outB > outA; }
  bool any() const { return hasIn() || hasOut(); }
};

// A clip as the app describes it: [start, end) of a source, with gain,
// played backwards if `reverse`, with fades.
struct ClipSpec {
  int64_t start = 0, end = 0;
  float gain = 1.0f;
  Fades fades;
  bool reverse = false;
};

// Fade curve: sin² of a quarter turn — starts and ends flat, so a fade never
// clicks at either end. x in [0, 1].
float fadeCurve(float x);

// One clip of the edit list, placed on the timeline (wiki/decisions/
// d012-chop-model.md).
struct TimelineClip {
  int64_t srcStart, srcEnd;  // frames of the recording, end exclusive
  int64_t tStart;            // where it starts on the timeline
  float gain;
  int64_t half;  // half-width of the crossfade at the join with the previous
                 // clip (0 for the first clip)
  bool reverse = false;
  Fades fades;

  int64_t length() const { return srcEnd - srcStart; }
  // Source frame for the clip's k-th frame (k may run past either end, for
  // join crossfades: playback simply continues in its direction).
  int64_t srcIndex(int64_t k) const {
    return reverse ? srcEnd - 1 - k : srcStart + k;
  }
  // Gain × fades at the clip's k-th frame.
  float gainAt(int64_t k) const {
    if (!fades.any()) return gain;
    const double x = static_cast<double>(k) + 0.5;
    float g = gain;
    if (fades.hasIn()) {
      g *= fadeCurve(static_cast<float>((x - fades.inA) /
                                        (fades.inB - fades.inA)));
    }
    if (fades.hasOut()) {
      g *= fadeCurve(static_cast<float>((fades.outB - x) /
                                        (fades.outB - fades.outA)));
    }
    return g;
  }
};

// One clip list over one source file (a take's recording or its render),
// placed at `offset` on the timeline.
struct Track {
  std::shared_ptr<MappedWav> src;  // the recording, or a render of it (M4)
  std::vector<TimelineClip> clips;
  int64_t length = 0;   // of the clip list
  int64_t offset = 0;   // where it starts on the timeline (M6 layers)
};

// What the player plays: one track (a take) or several mixed (a stack of
// layers, M6, wiki/features/layers.md). Per-track gains live in the player
// (smoothed on the audio thread), indexed like `tracks`.
struct Timeline {
  std::vector<Track> tracks;
  int64_t length = 0;         // end of the last track
  bool fadeEdges = false;     // 5 ms fade at each track's start and end
};

class Player {
 public:
  static constexpr uint32_t kJoinHalfFrames = 240;  // 10 ms crossfade per join
  static constexpr int32_t kMaxTracks = 16;          // layers in a stack
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

  // Replaces the edit list: n clips of [srcStart, srcEnd) of `sourcePath`
  // (null/empty = the take's recording; else e.g. a transposed render), with
  // gains; n == 0 plays the whole source. Positions, loops and scrub are in
  // timeline frames. Returns the new timeline length, or -1 if the source
  // can't be opened. The caller re-seeks.
  // fades (4 per clip: inA, inB, outA, outB) and reverse may be null (no
  // fades / forwards).
  int64_t setClips(const char* sourcePath, const int64_t* srcStarts,
                   const int64_t* srcEnds, const float* gains,
                   const double* fades, const uint8_t* reverse, int32_t n);

  // Stack of layers (M6): opens no recording; then setStack().
  void openStack();
  // Replaces the stack: n tracks; track k plays clipCounts[k] clips (taken
  // in order from the flattened starts/ends/gains) of paths[k], starting at
  // offsets[k] on the timeline. Each track fades in/out over 5 ms at its
  // ends. Returns the stack length, or -1 if a source can't be opened.
  int64_t setStack(int32_t n, const char* const* paths,
                   const int64_t* offsets, const int32_t* clipCounts,
                   const int64_t* starts, const int64_t* ends,
                   const float* gains, const double* fades = nullptr,
                   const uint8_t* reverse = nullptr);
  // Volume of track k (mute/solo/volume), smoothed — never clicks.
  void setTrackGain(int32_t k, float gain);
  // Offline mix of the whole timeline at the current track volumes into a
  // mono float WAV (control thread). Returns false on error.
  bool bounce(const char* path);

  // Nearest zero crossing of the recording within ±radius of srcFrame (the
  // index of the first sample after the sign change), or srcFrame if none.
  int64_t zeroCrossing(int64_t srcFrame, int32_t radius) const;

  // Timeline frame → (source, frame in it); source null outside the timeline.
  std::pair<std::shared_ptr<MappedWav>, int64_t> sourceFrameAt(
      int64_t timelineFrame);

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

  // One track at its own frame u, with equal-power crossfades inside joins.
  static float trackAt(const Track& tr, int64_t u);
  // A track over src from n clip specs (n == 0: the whole source).
  static Track buildTrack(std::shared_ptr<MappedWav> src,
                          const ClipSpec* specs, int32_t n);
  // Flat arrays (as the C API passes them) → specs; null arrays = defaults.
  static std::vector<ClipSpec> specsFrom(const int64_t* s, const int64_t* e,
                                         const float* g, const double* fades,
                                         const uint8_t* rev, int32_t n);

 private:
  // Timeline frame: the tracks mixed at the current smoothed gains.
  float timelineAt(const Timeline* tl, int64_t t) const;
  float interp(const Timeline* tl, double pos) const;  // 4-point Hermite
  static Timeline* buildTimeline(std::shared_ptr<MappedWav> src,
                                 const ClipSpec* specs, int32_t n);
  void swapTimeline(Timeline* fresh);
  void stepTrackGains(size_t n);  // audio thread, once per output frame
  void prefetchLoop();
  void closeLocked();

  // Mapping (set while the audio thread is excluded).
  // The take's recording (zero-crossing snaps always use it).
  std::shared_ptr<MappedWav> recording_;

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
  std::atomic<float> trackTarget_[kMaxTracks];
  float trackGain_[kMaxTracks] = {};  // audio thread, smoothed
  std::mutex timelineMutex_;  // swap/delete vs prefetch reads

  std::thread prefetch_;
  std::atomic<bool> stopPrefetch_{false};
  std::mutex controlMutex_;
};

}  // namespace ps

#endif  // PS_PLAYER_H
