// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

// 64-bit file offsets on 32-bit Android, so takes can pass 2 GiB.
#define _FILE_OFFSET_BITS 64

#include "wav_writer.h"

#include <unistd.h>

#include <cstring>

namespace ps {
namespace {

void put16(uint8_t* p, uint16_t v) {
  p[0] = static_cast<uint8_t>(v);
  p[1] = static_cast<uint8_t>(v >> 8);
}

void put32(uint8_t* p, uint32_t v) {
  for (int i = 0; i < 4; ++i) p[i] = static_cast<uint8_t>(v >> (8 * i));
}

// RIFF / fmt (IEEE float, 18 bytes) / fact / data. 58 bytes in total.
void buildHeader(uint8_t* h, uint32_t sampleRate, uint32_t frames) {
  const uint32_t dataBytes = frames * 4u;
  std::memcpy(h + 0, "RIFF", 4);
  put32(h + 4, 50u + dataBytes);
  std::memcpy(h + 8, "WAVE", 4);
  std::memcpy(h + 12, "fmt ", 4);
  put32(h + 16, 18);
  put16(h + 20, 3);               // WAVE_FORMAT_IEEE_FLOAT
  put16(h + 22, 1);               // mono
  put32(h + 24, sampleRate);
  put32(h + 28, sampleRate * 4);  // byte rate
  put16(h + 32, 4);               // block align
  put16(h + 34, 32);              // bits per sample
  put16(h + 36, 0);               // cbSize
  std::memcpy(h + 38, "fact", 4);
  put32(h + 42, 4);
  put32(h + 46, frames);
  std::memcpy(h + 50, "data", 4);
  put32(h + 54, dataBytes);
}

}  // namespace

bool WavWriter::open(const char* path, uint32_t sampleRate) {
  close();
  file_ = std::fopen(path, "wb");
  if (!file_) return false;
  sampleRate_ = sampleRate;
  frames_ = 0;
  full_ = false;
  failed_ = false;
  uint8_t header[kHeaderBytes];
  buildHeader(header, sampleRate_, 0);
  if (std::fwrite(header, 1, sizeof header, file_) != sizeof header ||
      std::fflush(file_) != 0) {
    std::fclose(file_);
    file_ = nullptr;
    return false;
  }
  return true;
}

bool WavWriter::write(const float* samples, size_t count) {
  if (!file_ || failed_ || full_) return false;
  const uint64_t room = kMaxDataBytes / 4 - frames_;
  if (count > room) {
    count = static_cast<size_t>(room);
    full_ = true;
  }
  if (count > 0 &&
      std::fwrite(samples, sizeof(float), count, file_) != count) {
    failed_ = true;
    return false;
  }
  frames_ += count;
  return !full_;
}

bool WavWriter::updateHeader() {
  if (!file_) return false;
  uint8_t header[kHeaderBytes];
  buildHeader(header, sampleRate_, static_cast<uint32_t>(frames_));
  // Seek back with SEEK_END rather than ftell(): `long` is 32-bit on 32-bit
  // Android.
  bool ok = std::fseek(file_, 0, SEEK_SET) == 0 &&
            std::fwrite(header, 1, sizeof header, file_) == sizeof header &&
            std::fseek(file_, 0, SEEK_END) == 0 && std::fflush(file_) == 0;
  if (!ok) failed_ = true;
  return ok;
}

bool WavWriter::close() {
  if (!file_) return true;
  bool ok = updateHeader() && !failed_;
  ::fsync(fileno(file_));
  ok = (std::fclose(file_) == 0) && ok;
  file_ = nullptr;
  return ok;
}

}  // namespace ps
