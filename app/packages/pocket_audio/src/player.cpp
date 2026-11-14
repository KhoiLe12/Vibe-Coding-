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

Player::Player() = default;

Player::~Player() { close(); }

float Player::sampleAt(int64_t i) const {
  if (i < 0 || i >= frames_) return 0.0f;
  float s;
  std::memcpy(&s, samples_ + 4 * i, 4);  // data starts at byte 58: unaligned
  return s;
}

float Player::interp(double pos) const {
  const double fl = std::floor(pos);
  const int64_t i = static_cast<int64_t>(fl);
  const float t = static_cast<float>(pos - fl);
  const float y0 = sampleAt(i - 1), y1 = sampleAt(i), y2 = sampleAt(i + 1),
              y3 = sampleAt(i + 2);
  const float c1 = 0.5f * (y2 - y0);
  const float c2 = y0 - 2.5f * y1 + 2.0f * y2 - 0.5f * y3;
  const float c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);
  return ((c3 * t + c2) * t + c1) * t + y1;
}

void Player::render(float* out, uint32_t frames, uint32_t channels) {
  inRender_.fetch_add(1);
  if (!active_.load()) {
    inRender_.fetch_sub(1);
    return;
  }

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
    pos_ = static_cast<double>(std::min<int64_t>(req, frames_));
    finished_.store(false);
  }

  if (scrubMode_) {
    const double shuttle = shuttle_.load();
    const double target = scrubTarget_.load();
    for (uint32_t i = 0; i < frames; ++i) {
      const double want =
          shuttle != 0.0
              ? shuttle
              : std::clamp((target - pos_) / kChaseFrames, -kMaxSpeed, kMaxSpeed);
      velocity_ += (want - velocity_) * kVelocityAlpha;
      pos_ += velocity_;
      if (pos_ < 0.0 || pos_ > static_cast<double>(frames_ - 1)) {
        pos_ = std::clamp(pos_, 0.0, std::max(0.0, static_cast<double>(frames_ - 1)));
        velocity_ = 0.0;
      }
      if (scrubGain_ < 1.0f) scrubGain_ = std::min(1.0f, scrubGain_ + kRampStep);
      const float amp = scrubGain_ *
                        static_cast<float>(std::min(1.0, std::fabs(velocity_) /
                                                             kQuietSpeed));
      float s = interp(pos_) * amp;
      if (xfade_) {
        const float w = static_cast<float>(xfadeT_) / kFadeFrames;
        s += sampleAt(static_cast<int64_t>(fromPos_)) * fromGain_ * (1.0f - w);
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
      s += sampleAt(static_cast<int64_t>(fromPos_)) * fromGain_ * (1.0f - w);
      // A loop wrap fades the new stream in under the old; a seek's new
      // stream also gets the play ramp.
      inGain *= w;
      fromPos_ += 1.0;
      if (++xfadeT_ >= kFadeFrames) xfade_ = false;
    }
    s += sampleAt(p) * inGain;
    for (uint32_t c = 0; c < channels; ++c) out[i * channels + c] += s;
    if (playGain_ > 0.0f) pos_ += 1.0;

    if (!looping && pos_ >= static_cast<double>(frames_)) {
      pos_ = static_cast<double>(frames_);
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
  unmapLocked();

  std::FILE* f = std::fopen(path, "rb");
  if (!f) return PS_ERROR_FILE;
  uint32_t sampleRate = 0;
  long dataOffset = 0;
  uint64_t frames = 0;
  const bool ok = probeWav(f, &sampleRate, &dataOffset, &frames);
  std::fclose(f);
  if (!ok) return PS_ERROR_FILE;

  const int fd = ::open(path, O_RDONLY);
  if (fd < 0) return PS_ERROR_FILE;
  struct stat st;
  if (::fstat(fd, &st) != 0 || st.st_size <= dataOffset) {
    ::close(fd);
    return PS_ERROR_FILE;
  }
  void* m = ::mmap(nullptr, static_cast<size_t>(st.st_size), PROT_READ,
                   MAP_SHARED, fd, 0);
  ::close(fd);  // the mapping stays valid
  if (m == MAP_FAILED) return PS_ERROR_FILE;

  map_ = static_cast<const uint8_t*>(m);
  mapBytes_ = static_cast<size_t>(st.st_size);
  samples_ = map_ + dataOffset;
  frames_ = std::min<int64_t>(static_cast<int64_t>(frames),
                              static_cast<int64_t>((mapBytes_ - dataOffset) / 4));
  sampleRate_ = sampleRate;

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
  length_.store(frames_);

  stopPrefetch_.store(false);
  prefetch_ = std::thread(&Player::prefetchLoop, this);
  active_.store(true);
  return PS_OK;
}

void Player::close() {
  std::lock_guard<std::mutex> lock(controlMutex_);
  unmapLocked();
  playing_.store(false);
  length_.store(0);
  position_.store(0);
}

void Player::unmapLocked() {
  active_.store(false);
  while (inRender_.load() != 0) std::this_thread::yield();
  if (prefetch_.joinable()) {
    stopPrefetch_.store(true);
    prefetch_.join();
  }
  if (map_) ::munmap(const_cast<uint8_t*>(map_), mapBytes_);
  map_ = nullptr;
  samples_ = nullptr;
  mapBytes_ = 0;
  frames_ = 0;
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
  const long page = ::sysconf(_SC_PAGESIZE);
  const uint8_t* base = map_;
  const size_t bytes = mapBytes_;
  const uintptr_t dataStart = static_cast<uintptr_t>(samples_ - map_);
  auto touch = [&](int64_t centre) {
    const int64_t from = std::max<int64_t>(0, centre - kPrefetchBack);
    const int64_t to = std::min<int64_t>(frames_, centre + kPrefetchAhead);
    if (to <= from) return;
    size_t a = dataStart + static_cast<size_t>(from) * 4;
    size_t b = std::min(bytes, dataStart + static_cast<size_t>(to) * 4);
    a -= a % static_cast<size_t>(page);
    ::madvise(const_cast<uint8_t*>(base + a), b - a, MADV_WILLNEED);
  };
  while (!stopPrefetch_.load()) {
    touch(position_.load());
    if (scrubRequested_.load()) {
      touch(static_cast<int64_t>(scrubTarget_.load()));
    }
    if (loopEnd_.load() > loopStart_.load()) touch(loopStart_.load());
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
  }
}

}  // namespace ps
