// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Streaming writer for mono 32-bit float WAV files (wiki/decisions/
// d007-recording-format.md). The header's size fields are patched by
// updateHeader(), so a file cut short by a crash is still a valid WAV holding
// everything up to the last update. Not real-time safe: writer thread only.

#ifndef PS_WAV_WRITER_H
#define PS_WAV_WRITER_H

#include <cstdint>
#include <cstdio>

namespace ps {

class WavWriter {
 public:
  // RIFF sizes are 32-bit; keep a margin below 4 GiB for the header.
  static constexpr uint64_t kMaxDataBytes = 0xFFFFFFFFull - 1024;
  static constexpr long kHeaderBytes = 58;

  WavWriter() = default;
  ~WavWriter() { close(); }
  WavWriter(const WavWriter&) = delete;
  WavWriter& operator=(const WavWriter&) = delete;

  bool open(const char* path, uint32_t sampleRate);
  bool isOpen() const { return file_ != nullptr; }

  // Appends samples. Returns false on an I/O error or when the file is full;
  // in both cases nothing more is written.
  bool write(const float* samples, size_t count);

  // Patches RIFF/fact/data sizes and flushes to the OS.
  bool updateHeader();

  // updateHeader() + fsync + fclose. Safe to call twice.
  bool close();

  uint64_t frames() const { return frames_; }
  bool full() const { return full_; }

 private:
  std::FILE* file_ = nullptr;
  uint32_t sampleRate_ = 0;
  uint64_t frames_ = 0;
  bool full_ = false;
  bool failed_ = false;
};

}  // namespace ps

#endif  // PS_WAV_WRITER_H
