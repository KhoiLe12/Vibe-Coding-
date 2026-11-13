// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

#define _FILE_OFFSET_BITS 64

#include "player.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <vector>

#include "pocket_audio.h"
#include "recorder.h"

namespace ps {
namespace {

constexpr size_t kRingCapacity = size_t{1} << 17;  // ~2.7 s at 48 kHz
constexpr size_t kReadChunk = 8192;
constexpr float kRampStep = 1.0f / 240.0f;  // 0→1 in 5 ms at 48 kHz

uint32_t get32(const uint8_t* p) {
  return p[0] | (p[1] << 8) | (p[2] << 16) | (static_cast<uint32_t>(p[3]) << 24);
}
uint16_t get16(const uint8_t* p) { return static_cast<uint16_t>(p[0] | (p[1] << 8)); }

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

Player::Player() : ring_(kRingCapacity) {}

Player::~Player() { close(); }

void Player::render(float* out, uint32_t frames, uint32_t channels) {
  inRender_.fetch_add(1);
  if (!active_.load()) {
    inRender_.fetch_sub(1);
    return;
  }
  const float target = playing_.load(std::memory_order_relaxed) ? 1.0f : 0.0f;
  float block[256];
  uint32_t done = 0;
  while (done < frames) {
    // Fully paused: consume nothing, so the position stays put.
    if (gain_ == 0.0f && target == 0.0f) break;
    const uint32_t want = std::min<uint32_t>(frames - done, 256);
    const size_t got = ring_.read(block, want);
    for (size_t i = 0; i < got; ++i) {
      if (gain_ < target) gain_ = std::min(target, gain_ + kRampStep);
      else if (gain_ > target) gain_ = std::max(target, gain_ - kRampStep);
      const float s = block[i] * gain_;
      float* frame = out + (done + i) * channels;
      for (uint32_t c = 0; c < channels; ++c) frame[c] += s;
    }
    position_.fetch_add(static_cast<int64_t>(got), std::memory_order_relaxed);
    done += static_cast<uint32_t>(got);
    if (got < want) {
      if (readerDone_.load() && ring_.available() == 0) {
        finished_.store(true);
        playing_.store(false);
        gain_ = 0.0f;
      }
      break;  // underrun or end: rest of the buffer stays silent
    }
  }
  inRender_.fetch_sub(1);
}

int32_t Player::open(const char* path) {
  std::lock_guard<std::mutex> lock(controlMutex_);
  active_.store(false);
  while (inRender_.load() != 0) std::this_thread::yield();
  stopReader();
  if (file_) std::fclose(file_);
  file_ = std::fopen(path, "rb");
  if (!file_) return PS_ERROR_FILE;
  uint32_t sampleRate = 0;
  uint64_t frames = 0;
  if (!probeWav(file_, &sampleRate, &dataOffset_, &frames)) {
    std::fclose(file_);
    file_ = nullptr;
    return PS_ERROR_FILE;
  }
  length_.store(static_cast<int64_t>(frames));
  playing_.store(false);
  startReader(0);
  return PS_OK;
}

void Player::close() {
  std::lock_guard<std::mutex> lock(controlMutex_);
  active_.store(false);
  while (inRender_.load() != 0) std::this_thread::yield();
  stopReader();
  if (file_) std::fclose(file_);
  file_ = nullptr;
  playing_.store(false);
  length_.store(0);
  position_.store(0);
}

int32_t Player::seek(int64_t frame) {
  std::lock_guard<std::mutex> lock(controlMutex_);
  if (!file_) return PS_ERROR_FILE;
  active_.store(false);
  while (inRender_.load() != 0) std::this_thread::yield();
  stopReader();
  startReader(std::clamp<int64_t>(frame, 0, length_.load()));
  return PS_OK;
}

void Player::startReader(int64_t fromFrame) {
  ring_.reset();
  readPos_ = fromFrame;
  position_.store(fromFrame);
  finished_.store(false);
  readerDone_.store(false);
  gain_ = 0.0f;  // audio thread is excluded (active_ false), so this is safe
  stopReaderFlag_.store(false);
  reader_ = std::thread(&Player::readerLoop, this);
  // Let the reader prefill a little so playback starts with audio.
  for (int i = 0; i < 200 && ring_.available() < 4096 && !readerDone_.load();
       ++i) {
    std::this_thread::sleep_for(std::chrono::microseconds(250));
  }
  active_.store(true);
}

void Player::stopReader() {
  if (!reader_.joinable()) return;
  stopReaderFlag_.store(true);
  reader_.join();
}

void Player::readerLoop() {
  std::vector<float> buf(kReadChunk);
  const int64_t length = length_.load();
  fseeko(file_, static_cast<off_t>(dataOffset_) + static_cast<off_t>(readPos_) * 4,
         SEEK_SET);
  while (!stopReaderFlag_.load()) {
    const size_t room = ring_.capacity() - ring_.available();
    const int64_t left = length - readPos_;
    if (left <= 0) {
      readerDone_.store(true);
      return;
    }
    if (room < kReadChunk / 2) {
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
      continue;
    }
    const size_t want = static_cast<size_t>(
        std::min<int64_t>(left, static_cast<int64_t>(std::min(room, kReadChunk))));
    const size_t got = std::fread(buf.data(), sizeof(float), want, file_);
    if (got == 0) {
      readerDone_.store(true);
      return;
    }
    ring_.write(buf.data(), got);
    readPos_ += static_cast<int64_t>(got);
  }
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
    const size_t want = static_cast<size_t>(std::min<uint64_t>(left, buf.size()));
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

}  // namespace ps
