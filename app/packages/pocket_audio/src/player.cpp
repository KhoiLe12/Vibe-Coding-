// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

#define _FILE_OFFSET_BITS 64

#include "player.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <vector>

#include "pocket_audio.h"
#include "recorder.h"
#include "wav_writer.h"

namespace ps {
namespace {

constexpr float kRampStep = 1.0f / Player::kFadeFrames;  // 0→1 in 5 ms
// Scrub dynamics (frames are at 48 kHz).
// Position chases the finger with time constant kChase; velocity is smoothed
// with kSmooth. This is a 2nd-order system that overshoots (the tape runs past
// the finger and back) unless kChase >= 4 * kSmooth; 80 ms vs 15 ms keeps it
// slightly overdamped.
constexpr double kChaseFrames = 0.080 * 48000;
constexpr double kVelocityAlpha = 1.0 / (0.015 * 48000);
constexpr double kMaxSpeed = 8.0;  // × real time
// Below this speed the tape "head" fades out, like tape slowing to a stop.
constexpr double kQuietSpeed = 0.25;
// Prefetch window around the playhead.
constexpr int64_t kPrefetchBack = 2 * 48000;
constexpr int64_t kPrefetchAhead = 4 * 48000;

uint32_t get32(const uint8_t* p) {
  return p[0] | (p[1] << 8) | (p[2] << 16) | (static_cast<uint32_t>(p[3]) << 24);
}
uint16_t get16(const uint8_t* p) {
  return static_cast<uint16_t>(p[0] | (p[1] << 8));
}

}  // namespace

bool probeWav(std::FILE* f, uint32_t* sampleRate, long* dataOffset,
              uint64_t* frames) {
  uint8_t h[12];
  if (std::fseek(f, 0, SEEK_SET) != 0 || std::fread(h, 1, 12, f) != 12 ||
      std::memcmp(h, "RIFF", 4) != 0 || std::memcmp(h + 8, "WAVE", 4) != 0) {
    return false;
  }
  bool haveFmt = false;
  long pos = 12;
  for (int guard = 0; guard < 32; ++guard) {
    uint8_t c[8];
    if (std::fseek(f, pos, SEEK_SET) != 0 || std::fread(c, 1, 8, f) != 8) {
      return false;
    }
    const uint32_t size = get32(c + 4);
    if (std::memcmp(c, "fmt ", 4) == 0) {
      uint8_t fmt[16];
      if (size < 16 || std::fread(fmt, 1, 16, f) != 16) return false;
      const uint16_t tag = get16(fmt), channels = get16(fmt + 2),
                     bits = get16(fmt + 14);
      if (tag != 3 || channels != 1 || bits != 32) return false;
      *sampleRate = get32(fmt + 4);
      haveFmt = true;
    } else if (std::memcmp(c, "data", 4) == 0) {
      if (!haveFmt) return false;
      *dataOffset = pos + 8;
      std::fseek(f, 0, SEEK_END);
      const long long fileBytes = static_cast<long long>(ftello(f));
      const uint64_t onDisk =
          static_cast<uint64_t>(std::max<long long>(0, fileBytes - pos - 8)) / 4;
      // Our recorder writes data last, so everything after the chunk header
      // is audio even if the size field lags behind (crash).
      *frames = std::max<uint64_t>(size / 4, onDisk);
      return true;
    }
    pos += 8 + static_cast<long>(size) + (size & 1);
  }
  return false;
}

bool buildPeaksFromWav(const char* wavPath, const char* peaksPath,
                       uint32_t blockFrames) {
  std::FILE* f = std::fopen(wavPath, "rb");
  if (!f) return false;
  uint32_t sampleRate = 0;
  long dataOffset = 0;
  uint64_t frames = 0;
  if (!probeWav(f, &sampleRate, &dataOffset, &frames)) {
    std::fclose(f);
    return false;
  }
  fseeko(f, static_cast<off_t>(dataOffset), SEEK_SET);
  std::vector<float> peaks;
  peaks.reserve(static_cast<size_t>(2 * (frames / blockFrames + 1)));
  std::vector<float> buf(blockFrames * 64);
  uint64_t left = frames;
  float lo = 0, hi = 0;
  uint32_t fill = 0;
  while (left > 0) {
    const size_t want =
        static_cast<size_t>(std::min<uint64_t>(left, buf.size()));
    const size_t got = std::fread(buf.data(), sizeof(float), want, f);
    if (got == 0) break;
    for (size_t i = 0; i < got; ++i) {
      const float s = buf[i];
      if (fill == 0) {
        lo = hi = s;
      } else {
        lo = std::min(lo, s);
        hi = std::max(hi, s);
      }
      if (++fill == blockFrames) {
        peaks.push_back(lo);
        peaks.push_back(hi);
        fill = 0;
      }
    }
    left -= got;
  }
  if (fill > 0) {
    peaks.push_back(lo);
    peaks.push_back(hi);
  }
  std::fclose(f);
  return writePeaksFile(peaksPath, blockFrames, peaks);
}

// ---------------------------------------------------------------------------

Player::Player() {
  for (int k = 0; k < kMaxTracks; ++k) {
    trackTarget_[k].store(1.0f);
    trackGain_[k] = 1.0f;
  }
}

void Player::stepTrackGains(size_t n) {
  for (size_t k = 0; k < n && k < static_cast<size_t>(kMaxTracks); ++k) {
    const float target = trackTarget_[k].load(std::memory_order_relaxed);
    float& g = trackGain_[k];
    if (g < target) g = std::min(target, g + kRampStep);
    else if (g > target) g = std::max(target, g - kRampStep);
  }
}

Player::~Player() { close(); }

MappedWav::~MappedWav() {
  if (map) ::munmap(const_cast<uint8_t*>(map), bytes);
}

std::shared_ptr<MappedWav> MappedWav::open(const char* path) {
  std::FILE* f = std::fopen(path, "rb");
  if (!f) return nullptr;
  uint32_t sampleRate = 0;
  long dataOffset = 0;
  uint64_t frames = 0;
  const bool ok = probeWav(f, &sampleRate, &dataOffset, &frames);
  std::fclose(f);
  if (!ok) return nullptr;
  const int fd = ::open(path, O_RDONLY);
  if (fd < 0) return nullptr;
  struct stat st;
  if (::fstat(fd, &st) != 0 || st.st_size <= dataOffset) {
    ::close(fd);
    return nullptr;
  }
  void* m = ::mmap(nullptr, static_cast<size_t>(st.st_size), PROT_READ,
                   MAP_SHARED, fd, 0);
  ::close(fd);  // the mapping stays valid
  if (m == MAP_FAILED) return nullptr;
  auto w = std::make_shared<MappedWav>();
  w->path = path;
  w->map = static_cast<const uint8_t*>(m);
  w->bytes = static_cast<size_t>(st.st_size);
  w->samples = w->map + dataOffset;
  w->frames = std::min<int64_t>(static_cast<int64_t>(frames),
                                static_cast<int64_t>((w->bytes - dataOffset) / 4));
  w->sampleRate = sampleRate;
  return w;
}

float MappedWav::at(int64_t i) const {
  if (i < 0 || i >= frames) return 0.0f;
  float s;
  std::memcpy(&s, samples + 4 * i, 4);
  return s;
}

float Player::trackAt(const Track& tr, int64_t t) {
  if (t < 0 || t >= tr.length || tr.clips.empty()) return 0.0f;
  const auto& clips = tr.clips;
  // Last clip starting at or before t.
  size_t lo = 0, hi = clips.size();
  while (hi - lo > 1) {
    const size_t mid = (lo + hi) / 2;
    if (clips[mid].tStart <= t) lo = mid; else hi = mid;
  }
  const TimelineClip& c = clips[lo];
  // Join crossfade: centred on the join, `half` frames either side. The
  // outgoing clip runs past its end, the incoming one starts early.
  auto mix = [&](const TimelineClip& a, const TimelineClip& b) {
    const int64_t join = b.tStart;
    const float u = (static_cast<float>(t - (join - b.half)) + 0.5f) /
                    static_cast<float>(2 * b.half);
    constexpr float kHalfPi = 1.57079632679f;
    const float va = tr.src->at(a.srcEnd + (t - join)) * a.gain;
    const float vb = tr.src->at(b.srcStart + (t - join)) * b.gain;
    return va * std::cos(u * kHalfPi) + vb * std::sin(u * kHalfPi);
  };
  if (lo + 1 < clips.size()) {
    const TimelineClip& n = clips[lo + 1];
    if (t >= n.tStart - n.half) return mix(c, n);
  }
  if (lo > 0 && t < c.tStart + c.half) return mix(clips[lo - 1], c);
  return tr.src->at(c.srcStart + (t - c.tStart)) * c.gain;
}

float Player::timelineAt(const Timeline* tl, int64_t t) const {
  if (t < 0 || t >= tl->length) return 0.0f;
  float y = 0.0f;
  const size_t n = tl->tracks.size();
  for (size_t k = 0; k < n; ++k) {
    const Track& tr = tl->tracks[k];
    const int64_t u = t - tr.offset;
    if (u < 0 || u >= tr.length) continue;
    float g = trackGain_[k];
    if (g == 0.0f) continue;
    if (tl->fadeEdges) {
      // 5 ms in and out at the layer's ends, so no layer clicks on or off.
      const float fade = static_cast<float>(kFadeFrames);
      g *= std::min({1.0f, (static_cast<float>(u) + 0.5f) / fade,
                     (static_cast<float>(tr.length - u) - 0.5f) / fade});
    }
    y += trackAt(tr, u) * g;
  }
  return y;
}

float Player::interp(const Timeline* tl, double pos) const {
  const double fl = std::floor(pos);
  const int64_t i = static_cast<int64_t>(fl);
  const float t = static_cast<float>(pos - fl);
  const float y0 = timelineAt(tl, i - 1), y1 = timelineAt(tl, i),
              y2 = timelineAt(tl, i + 1), y3 = timelineAt(tl, i + 2);
  const float c1 = 0.5f * (y2 - y0);
  const float c2 = y0 - 2.5f * y1 + 2.0f * y2 - 0.5f * y3;
  const float c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);
  return ((c3 * t + c2) * t + c1) * t + y1;
}

Track Player::buildTrack(std::shared_ptr<MappedWav> src, const int64_t* s,
                         const int64_t* e, const float* g, int32_t n) {
  Track tr;
  const int64_t frames = src->frames;
  tr.src = std::move(src);
  if (n <= 0) {
    if (frames > 0) tr.clips.push_back({0, frames, 0, 1.0f, 0});
  } else {
    tr.clips.reserve(static_cast<size_t>(n));
    for (int32_t i = 0; i < n; ++i) {
      const int64_t a = std::clamp<int64_t>(s[i], 0, frames);
      const int64_t b = std::clamp<int64_t>(e[i], 0, frames);
      if (b > a) tr.clips.push_back({a, b, 0, g ? g[i] : 1.0f, 0});
    }
  }
  int64_t t = 0;
  for (size_t i = 0; i < tr.clips.size(); ++i) {
    TimelineClip& c = tr.clips[i];
    c.tStart = t;
    if (i > 0) {
      const TimelineClip& p = tr.clips[i - 1];
      c.half = std::min<int64_t>({kJoinHalfFrames, (p.srcEnd - p.srcStart) / 2,
                                  (c.srcEnd - c.srcStart) / 2});
      // Adjacent pieces of the recording need no crossfade.
      if (p.srcEnd == c.srcStart && p.gain == c.gain) c.half = 0;
    }
    t += c.srcEnd - c.srcStart;
  }
  tr.length = t;
  return tr;
}

Timeline* Player::buildTimeline(std::shared_ptr<MappedWav> src,
                                const int64_t* s, const int64_t* e,
                                const float* g, int32_t n) {
  auto* tl = new Timeline();
  tl->tracks.push_back(buildTrack(std::move(src), s, e, g, n));
  tl->length = tl->tracks[0].length;
  return tl;
}

void Player::swapTimeline(Timeline* fresh) {
  Timeline* old;
  {
    std::lock_guard<std::mutex> tlock(timelineMutex_);
    old = timeline_.exchange(fresh);
    length_.store(fresh->length);
  }
  // A render that loaded `old` may still be running; once inRender_ is seen
  // at 0, every later render uses `fresh`. Deleting `old` drops its sources;
  // a mapping goes away with its last owner.
  while (inRender_.load() != 0) std::this_thread::yield();
  delete old;
  // Keep loop and position inside the new timeline.
  if (loopEnd_.load() > fresh->length) setLoop(0, 0);
  if (position_.load() > fresh->length) seek(fresh->length);
}

int64_t Player::setClips(const char* sourcePath, const int64_t* srcStarts,
                         const int64_t* srcEnds, const float* gains,
                         int32_t n) {
  std::lock_guard<std::mutex> lock(controlMutex_);
  if (!recording_) return 0;
  std::shared_ptr<MappedWav> src = recording_;
  if (sourcePath && sourcePath[0] != '\0') {
    const Timeline* cur = timeline_.load();
    if (cur && !cur->tracks.empty() && cur->tracks[0].src->path == sourcePath) {
      src = cur->tracks[0].src;  // same render: no need to map it again
    } else {
      src = MappedWav::open(sourcePath);
      if (!src) return -1;
    }
  }
  Timeline* fresh = buildTimeline(std::move(src), srcStarts, srcEnds, gains, n);
  swapTimeline(fresh);
  return fresh->length;
}

void Player::openStack() {
  std::lock_guard<std::mutex> lock(controlMutex_);
  closeLocked();
  pos_ = 0.0;
  playGain_ = 0.0f;
  scrubMode_ = false;
  scrubGain_ = 0.0f;
  velocity_ = 0.0;
  xfade_ = false;
  seekRequest_.store(-1);
  loopStart_.store(0);
  loopEnd_.store(0);
  scrubRequested_.store(false);
  shuttle_.store(0.0);
  playing_.store(false);
  finished_.store(false);
  position_.store(0);
  for (int k = 0; k < kMaxTracks; ++k) {
    trackTarget_[k].store(1.0f);
    trackGain_[k] = 1.0f;
  }
  auto* tl = new Timeline();
  tl->fadeEdges = true;
  timeline_.store(tl);
  length_.store(0);
  stopPrefetch_.store(false);
  prefetch_ = std::thread(&Player::prefetchLoop, this);
  active_.store(true);
}

int64_t Player::setStack(int32_t n, const char* const* paths,
                         const int64_t* offsets, const int32_t* clipCounts,
                         const int64_t* starts, const int64_t* ends,
                         const float* gains) {
  std::lock_guard<std::mutex> lock(controlMutex_);
  if (n < 0 || n > kMaxTracks) return -1;
  auto* fresh = new Timeline();
  fresh->fadeEdges = true;
  const Timeline* cur = timeline_.load();
  int64_t at = 0;
  for (int32_t k = 0; k < n; ++k) {
    // Reuse mappings the current stack already has open.
    std::shared_ptr<MappedWav> src;
    if (cur) {
      for (const auto& tr : cur->tracks) {
        if (tr.src->path == paths[k]) src = tr.src;
      }
    }
    if (!src) src = MappedWav::open(paths[k]);
    if (!src) {
      delete fresh;
      return -1;
    }
    Track tr = buildTrack(std::move(src), starts + at, ends + at,
                          gains ? gains + at : nullptr, clipCounts[k]);
    at += clipCounts[k];
    tr.offset = std::max<int64_t>(0, offsets[k]);
    fresh->length = std::max(fresh->length, tr.offset + tr.length);
    fresh->tracks.push_back(std::move(tr));
  }
  swapTimeline(fresh);
  return fresh->length;
}

void Player::setTrackGain(int32_t k, float gain) {
  if (k >= 0 && k < kMaxTracks) trackTarget_[k].store(gain);
}

bool Player::bounce(const char* path) {
  std::lock_guard<std::mutex> lock(controlMutex_);
  const Timeline* tl = timeline_.load();
  if (!tl) return false;
  // Mixed at the target volumes (no smoothing), exactly as playback settles.
  Timeline copy;
  {
    std::lock_guard<std::mutex> tlock(timelineMutex_);
    copy = *tl;  // shares the mappings; safe from a concurrent swap
  }
  float g[kMaxTracks];
  for (int k = 0; k < kMaxTracks; ++k) g[k] = trackTarget_[k].load();
  WavWriter w;
  if (!w.open(path, copy.tracks.empty() ? 48000 : copy.tracks[0].src->sampleRate)) {
    return false;
  }
  std::vector<float> buf(16384);
  for (int64_t t0 = 0; t0 < copy.length; t0 += static_cast<int64_t>(buf.size())) {
    const size_t n = static_cast<size_t>(
        std::min<int64_t>(static_cast<int64_t>(buf.size()), copy.length - t0));
    for (size_t i = 0; i < n; ++i) {
      const int64_t t = t0 + static_cast<int64_t>(i);
      float y = 0.0f;
      for (size_t k = 0; k < copy.tracks.size(); ++k) {
        const Track& tr = copy.tracks[k];
        const int64_t u = t - tr.offset;
        if (u < 0 || u >= tr.length || g[k] == 0.0f) continue;
        float gk = g[k];
        if (copy.fadeEdges) {
          const float fade = static_cast<float>(kFadeFrames);
          gk *= std::min({1.0f, (static_cast<float>(u) + 0.5f) / fade,
                          (static_cast<float>(tr.length - u) - 0.5f) / fade});
        }
        y += trackAt(tr, u) * gk;
      }
      buf[i] = y;
    }
    if (!w.write(buf.data(), n)) {
      w.close();
      return false;
    }
  }
  return w.close();
}

int64_t Player::zeroCrossing(int64_t srcFrame, int32_t radius) const {
  const MappedWav* w = recording_.get();
  if (!w || w->frames < 2) return srcFrame;
  for (int32_t d = 0; d <= radius; ++d) {
    for (const int64_t k : {srcFrame + d, srcFrame - d}) {
      if (k <= 0 || k >= w->frames) continue;
      const float a = w->at(k - 1), b = w->at(k);
      if (b == 0.0f || (a < 0.0f) != (b < 0.0f)) return k;
    }
  }
  return srcFrame;
}

std::pair<std::shared_ptr<MappedWav>, int64_t> Player::sourceFrameAt(
    int64_t t) {
  std::lock_guard<std::mutex> lock(timelineMutex_);
  const Timeline* tl = timeline_.load();
  if (!tl || t < 0 || t >= tl->length) return {nullptr, -1};
  for (const auto& tr : tl->tracks) {
    const int64_t u = t - tr.offset;
    if (u < 0 || u >= tr.length) continue;
    for (const auto& c : tr.clips) {
      if (u < c.tStart + (c.srcEnd - c.srcStart)) {
        return {tr.src, c.srcStart + (u - c.tStart)};
      }
    }
  }
  return {nullptr, -1};
}

void Player::render(float* out, uint32_t frames, uint32_t channels) {
  inRender_.fetch_add(1);
  const Timeline* tl = timeline_.load(std::memory_order_acquire);
  if (!active_.load() || tl == nullptr) {
    inRender_.fetch_sub(1);
    return;
  }
  const int64_t length = tl->length;

  // ---- control changes, once per callback ----
  const bool wantScrub = scrubRequested_.load();
  if (wantScrub && !scrubMode_) {
    scrubMode_ = true;
    // Carry on at the current speed so entering scrub never clicks.
    velocity_ = playGain_ > 0.0f ? 1.0 : 0.0;
    scrubGain_ = playGain_;
    playGain_ = 0.0f;
  } else if (!wantScrub && scrubMode_) {
    // Stay where the tape is (what was last heard), not where the finger is:
    // the tape may lag far behind a fast finger.
    const double target = pos_;
    const float amp = scrubGain_ *
                      static_cast<float>(std::min(1.0, std::fabs(velocity_) /
                                                           kQuietSpeed));
    if (amp > 0.0f) {
      xfade_ = true;
      fromPos_ = pos_;
      fromGain_ = amp;
      xfadeT_ = 0;
    }
    pos_ = std::floor(target);
    scrubMode_ = false;
    shuttle_.store(0.0);
    const bool resume = resumeAfterScrub_.load();
    playing_.store(resume);
    playGain_ = 0.0f;  // fades in (if resuming) while the scrub sound fades out
    finished_.store(false);
  }
  const int64_t req = seekRequest_.exchange(-1);
  if (req >= 0) {
    if (!scrubMode_ && playGain_ > 0.0f) {
      xfade_ = true;
      fromPos_ = pos_;
      fromGain_ = playGain_;
      xfadeT_ = 0;
      playGain_ = 0.0f;  // new position fades in
    }
    pos_ = static_cast<double>(std::min<int64_t>(req, length));
    finished_.store(false);
  }

  if (scrubMode_) {
    const double shuttle = shuttle_.load();
    const double target = scrubTarget_.load();
    for (uint32_t i = 0; i < frames; ++i) {
      stepTrackGains(tl->tracks.size());
      const double want =
          shuttle != 0.0
              ? shuttle
              : std::clamp((target - pos_) / kChaseFrames, -kMaxSpeed, kMaxSpeed);
      velocity_ += (want - velocity_) * kVelocityAlpha;
      pos_ += velocity_;
      if (pos_ < 0.0 || pos_ > static_cast<double>(length - 1)) {
        pos_ = std::clamp(pos_, 0.0, std::max(0.0, static_cast<double>(length - 1)));
        velocity_ = 0.0;
      }
      if (scrubGain_ < 1.0f) scrubGain_ = std::min(1.0f, scrubGain_ + kRampStep);
      const float amp = scrubGain_ *
                        static_cast<float>(std::min(1.0, std::fabs(velocity_) /
                                                             kQuietSpeed));
      float s = interp(tl, pos_) * amp;
      if (xfade_) {
        const float w = static_cast<float>(xfadeT_) / kFadeFrames;
        s += timelineAt(tl, static_cast<int64_t>(fromPos_)) * fromGain_ * (1.0f - w);
        fromPos_ += 1.0;
        if (++xfadeT_ >= kFadeFrames) xfade_ = false;
      }
      for (uint32_t c = 0; c < channels; ++c) out[i * channels + c] += s;
    }
    position_.store(static_cast<int64_t>(pos_), std::memory_order_relaxed);
    inRender_.fetch_sub(1);
    return;
  }

  const float target = playing_.load(std::memory_order_relaxed) ? 1.0f : 0.0f;
  const int64_t loopStart = loopStart_.load(std::memory_order_relaxed);
  const int64_t loopEnd = loopEnd_.load(std::memory_order_relaxed);
  const bool looping = loopEnd > loopStart;
  // The wrap starts this many frames before the loop end and lands the same
  // distance before the loop start, so the period is exactly end - start.
  const int64_t lead = looping ? std::min<int64_t>(
                                     {static_cast<int64_t>(kFadeFrames),
                                      loopStart, (loopEnd - loopStart) / 2})
                               : 0;

  for (uint32_t i = 0; i < frames; ++i) {
    stepTrackGains(tl->tracks.size());
    if (playGain_ < target) {
      playGain_ = std::min(target, playGain_ + kRampStep);
    } else if (playGain_ > target) {
      playGain_ = std::max(target, playGain_ - kRampStep);
    }
    if (playGain_ == 0.0f && !xfade_) break;  // paused: hold the position

    int64_t p = static_cast<int64_t>(pos_);
    if (looping && playGain_ > 0.0f && !xfade_ && p >= loopEnd - lead) {
      xfade_ = true;
      fromPos_ = pos_;
      fromGain_ = 1.0f;
      xfadeT_ = 0;
      pos_ = static_cast<double>(loopStart - lead);
      p = static_cast<int64_t>(pos_);
    }

    float s = 0.0f;
    float inGain = playGain_;
    if (xfade_) {
      const float w = static_cast<float>(xfadeT_) / kFadeFrames;
      s += timelineAt(tl, static_cast<int64_t>(fromPos_)) * fromGain_ * (1.0f - w);
      // A loop wrap fades the new stream in under the old; a seek's new
      // stream also gets the play ramp.
      inGain *= w;
      fromPos_ += 1.0;
      if (++xfadeT_ >= kFadeFrames) xfade_ = false;
    }
    s += timelineAt(tl, p) * inGain;
    for (uint32_t c = 0; c < channels; ++c) out[i * channels + c] += s;
    if (playGain_ > 0.0f) pos_ += 1.0;

    if (!looping && pos_ >= static_cast<double>(length)) {
      pos_ = static_cast<double>(length);
      playing_.store(false);
      finished_.store(true);
      playGain_ = 0.0f;
      xfade_ = false;
      break;
    }
  }
  position_.store(static_cast<int64_t>(pos_), std::memory_order_relaxed);
  inRender_.fetch_sub(1);
}

int32_t Player::open(const char* path) {
  std::lock_guard<std::mutex> lock(controlMutex_);
  closeLocked();
  auto rec = MappedWav::open(path);
  if (!rec) return PS_ERROR_FILE;
  recording_ = rec;

  // Audio-thread state (the audio thread is excluded until active_).
  pos_ = 0.0;
  playGain_ = 0.0f;
  scrubMode_ = false;
  scrubGain_ = 0.0f;
  velocity_ = 0.0;
  xfade_ = false;
  seekRequest_.store(-1);
  loopStart_.store(0);
  loopEnd_.store(0);
  scrubRequested_.store(false);
  shuttle_.store(0.0);
  playing_.store(false);
  finished_.store(false);
  position_.store(0);
  for (int k = 0; k < kMaxTracks; ++k) {
    trackTarget_[k].store(1.0f);
    trackGain_[k] = 1.0f;
  }
  timeline_.store(buildTimeline(rec, nullptr, nullptr, nullptr, 0));
  length_.store(rec->frames);

  stopPrefetch_.store(false);
  prefetch_ = std::thread(&Player::prefetchLoop, this);
  active_.store(true);
  return PS_OK;
}

void Player::close() {
  std::lock_guard<std::mutex> lock(controlMutex_);
  closeLocked();
  playing_.store(false);
  length_.store(0);
  position_.store(0);
}

void Player::closeLocked() {
  active_.store(false);
  while (inRender_.load() != 0) std::this_thread::yield();
  if (prefetch_.joinable()) {
    stopPrefetch_.store(true);
    prefetch_.join();
  }
  {
    std::lock_guard<std::mutex> tlock(timelineMutex_);
    delete timeline_.exchange(nullptr);
  }
  recording_.reset();
}

int32_t Player::seek(int64_t frame) {
  if (length_.load() == 0 && !active_.load()) return PS_ERROR_FILE;
  frame = std::clamp<int64_t>(frame, 0, length_.load());
  position_.store(frame);
  finished_.store(false);
  seekRequest_.store(frame);
  return PS_OK;
}

void Player::setLoop(int64_t start, int64_t end) {
  const int64_t len = length_.load();
  start = std::clamp<int64_t>(start, 0, len);
  end = std::clamp<int64_t>(end, 0, len);
  if (end - start < 2 * static_cast<int64_t>(kFadeFrames)) start = end = 0;
  // Order matters for the audio thread: shrink to "off" first, then set.
  loopEnd_.store(0);
  loopStart_.store(start);
  loopEnd_.store(end);
}

void Player::beginScrub() {
  resumeAfterScrub_.store(playing_.load());
  scrubTarget_.store(static_cast<double>(position_.load()));
  shuttle_.store(0.0);
  scrubRequested_.store(true);
}

void Player::endScrub() { scrubRequested_.store(false); }

void Player::prefetchLoop() {
  const size_t page = static_cast<size_t>(::sysconf(_SC_PAGESIZE));
  // Positions are timeline frames; prefetch the source (recording or render)
  // around where each one maps. Holding the shared_ptr keeps the mapping
  // alive while madvise runs, even if the timeline is swapped meanwhile.
  auto touchT = [&](int64_t t) {
    // Every layer playing at t, not just the first.
    std::vector<std::pair<std::shared_ptr<MappedWav>, int64_t>> spots;
    {
      std::lock_guard<std::mutex> lock(timelineMutex_);
      const Timeline* tl = timeline_.load();
      if (!tl) return;
      for (const auto& tr : tl->tracks) {
        const int64_t u = std::clamp<int64_t>(t - tr.offset, 0, tr.length);
        for (const auto& c : tr.clips) {
          if (u < c.tStart + (c.srcEnd - c.srcStart)) {
            spots.emplace_back(tr.src, c.srcStart + (u - c.tStart));
            break;
          }
        }
      }
    }
    for (const auto& [src, centre] : spots) {
      const int64_t from = std::max<int64_t>(0, centre - kPrefetchBack);
      const int64_t to = std::min<int64_t>(src->frames, centre + kPrefetchAhead);
      if (to <= from) continue;
      const size_t dataStart = static_cast<size_t>(src->samples - src->map);
      size_t a = dataStart + static_cast<size_t>(from) * 4;
      const size_t b = std::min(src->bytes, dataStart + static_cast<size_t>(to) * 4);
      a -= a % page;
      ::madvise(const_cast<uint8_t*>(src->map + a), b - a, MADV_WILLNEED);
    }
  };
  while (!stopPrefetch_.load()) {
    touchT(position_.load());
    if (scrubRequested_.load()) {
      touchT(static_cast<int64_t>(scrubTarget_.load()));
    }
    if (loopEnd_.load() > loopStart_.load()) touchT(loopStart_.load());
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
  }
}

}  // namespace ps
