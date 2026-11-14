// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

#define _FILE_OFFSET_BITS 64

#include "exporter.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

#include "resampler.h"

namespace ps {
namespace {

constexpr int64_t kBlock = 8192;

void put16(uint8_t* p, uint32_t v) {
  p[0] = static_cast<uint8_t>(v);
  p[1] = static_cast<uint8_t>(v >> 8);
}
void put32(uint8_t* p, uint32_t v) {
  for (int i = 0; i < 4; ++i) p[i] = static_cast<uint8_t>(v >> (8 * i));
}

// Mono WAV writer for export formats. The header is written at close, when
// the length is known.
class PcmWriter {
 public:
  bool open(const char* path, uint32_t rate, int32_t bits) {
    f_ = std::fopen(path, "wb");
    rate_ = rate;
    bits_ = bits;
    if (!f_) return false;
    uint8_t blank[44] = {};
    return std::fwrite(blank, 1, 44, f_) == 44;  // header placeholder
  }

  bool write(const float* x, size_t n) {
    buf_.resize(n * 4);
    uint8_t* p = buf_.data();
    for (size_t i = 0; i < n; ++i) {
      const float s = x[i];
      if (bits_ == 32) {
        std::memcpy(p, &s, 4);
        p += 4;
      } else if (bits_ == 24) {
        const double v = std::clamp<double>(std::lround(s * 8388608.0),
                                            -8388608.0, 8388607.0);
        const int32_t q = static_cast<int32_t>(v);
        p[0] = static_cast<uint8_t>(q);
        p[1] = static_cast<uint8_t>(q >> 8);
        p[2] = static_cast<uint8_t>(q >> 16);
        p += 3;
      } else {
        // TPDF dither: sum of two uniform ±0.5 LSB noises.
        const double d = rnd() + rnd() - 1.0;
        const double v = std::clamp<double>(std::floor(s * 32768.0 + d + 0.5),
                                            -32768.0, 32767.0);
        const int32_t q = static_cast<int32_t>(v);
        p[0] = static_cast<uint8_t>(q);
        p[1] = static_cast<uint8_t>(q >> 8);
        p += 2;
      }
    }
    const size_t bytes = static_cast<size_t>(p - buf_.data());
    frames_ += n;
    return std::fwrite(buf_.data(), 1, bytes, f_) == bytes;
  }

  // loopEnd > 0 adds a smpl chunk looping [0, loopEnd) forever.
  bool close(uint64_t loopEnd) {
    if (!f_) return false;
    const uint32_t bytesPer = static_cast<uint32_t>(bits_ / 8);
    const uint64_t dataBytes = frames_ * bytesPer;
    bool ok = true;
    if (dataBytes & 1) ok = std::fputc(0, f_) != EOF;  // pad byte
    uint32_t smplBytes = 0;
    if (loopEnd > 0) {
      uint8_t s[8 + 36 + 24] = {};
      std::memcpy(s, "smpl", 4);
      put32(s + 4, 36 + 24);
      put32(s + 8 + 8, static_cast<uint32_t>(1000000000.0 / rate_));  // period ns
      put32(s + 8 + 12, 60);  // MIDI unity note: middle C
      put32(s + 8 + 28, 1);   // one loop
      uint8_t* l = s + 8 + 36;
      put32(l + 4, 0);        // forward loop
      put32(l + 8, 0);        // start
      put32(l + 12, static_cast<uint32_t>(loopEnd - 1));  // end (inclusive)
      ok = ok && std::fwrite(s, 1, sizeof s, f_) == sizeof s;
      smplBytes = sizeof s;
    }
    uint8_t h[44];
    std::memcpy(h, "RIFF", 4);
    put32(h + 4, static_cast<uint32_t>(36 + dataBytes + (dataBytes & 1) +
                                       smplBytes));
    std::memcpy(h + 8, "WAVEfmt ", 8);
    put32(h + 16, 16);
    put16(h + 20, bits_ == 32 ? 3 : 1);  // IEEE float / PCM
    put16(h + 22, 1);                    // mono
    put32(h + 24, rate_);
    put32(h + 28, rate_ * bytesPer);
    put16(h + 32, bytesPer);
    put16(h + 34, static_cast<uint32_t>(bits_));
    std::memcpy(h + 36, "data", 4);
    put32(h + 40, static_cast<uint32_t>(dataBytes));
    ok = ok && std::fseek(f_, 0, SEEK_SET) == 0 &&
         std::fwrite(h, 1, 44, f_) == 44;
    ok = (std::fclose(f_) == 0) && ok;
    f_ = nullptr;
    return ok;
  }

  void abandon() {
    if (f_) std::fclose(f_);
    f_ = nullptr;
  }

 private:
  double rnd() {
    seed_ = seed_ * 6364136223846793005ULL + 1442695040888963407ULL;
    return static_cast<double>(seed_ >> 11) * (1.0 / 9007199254740992.0);
  }

  std::FILE* f_ = nullptr;
  uint32_t rate_ = 48000;
  int32_t bits_ = 24;
  uint64_t frames_ = 0;
  uint64_t seed_ = 0x9E3779B97F4A7C15ULL;
  std::vector<uint8_t> buf_;
};

}  // namespace

bool exportWav(const ExportJob& job) {
  if (job.bits != 16 && job.bits != 24 && job.bits != 32) return false;
  if (job.sampleRate < 8000 || job.sampleRate > 192000) return false;
  auto src = MappedWav::open(job.source.c_str());
  if (!src) return false;
  const Track tr = Player::buildTrack(
      src, job.clips.data(), static_cast<int32_t>(job.clips.size()));
  const bool loop = job.loopFrames > 0;
  const int64_t n = loop ? std::min(job.loopFrames, tr.length) : tr.length;
  if (n <= 0) return false;
  const bool seam = loop && tr.length - n >= kSeamFrames;
  const int64_t edge = std::min<int64_t>(kEdgeFadeFrames, n / 2);

  // Output frame i of the (48 kHz) export, before resampling.
  constexpr float kHalfPi = 1.57079632679f;
  auto at = [&](int64_t i) -> float {
    if (loop) i = ((i % n) + n) % n;  // a loop wraps (also for resampling)
    else if (i < 0 || i >= n) return 0.0f;
    float y = Player::trackAt(tr, i);
    if (seam && i < kSeamFrames) {
      // The audio that followed the loop's end fades out over the head while
      // the head fades in: the wrap continues as the recording did.
      const float u = (static_cast<float>(i) + 0.5f) / kSeamFrames;
      y = y * std::sin(u * kHalfPi) +
          Player::trackAt(tr, n + i) * std::cos(u * kHalfPi);
    } else if (loop && !seam) {
      const float e = static_cast<float>(edge);
      y *= std::min({1.0f, (static_cast<float>(i) + 0.5f) / e,
                     (static_cast<float>(n - i) - 0.5f) / e});
    }
    return y;
  };
  auto fetch = [&](int64_t a, int64_t count, float* buf) {
    for (int64_t k = 0; k < count; ++k) buf[k] = at(a + k);
  };

  const std::string tmp = job.output + ".tmp";
  PcmWriter w;
  if (!w.open(tmp.c_str(), job.sampleRate, job.bits)) {
    w.abandon();
    std::remove(tmp.c_str());
    return false;
  }
  std::vector<float> buf(kBlock);
  bool ok = true;
  int64_t outLen = n;
  if (job.sampleRate == src->sampleRate) {
    for (int64_t j = 0; j < n && ok; j += kBlock) {
      const int64_t m = std::min(kBlock, n - j);
      fetch(j, m, buf.data());
      ok = w.write(buf.data(), static_cast<size_t>(m));
    }
  } else {
    const double step =
        static_cast<double>(src->sampleRate) / static_cast<double>(job.sampleRate);
    SincResampler rs(step);
    outLen = std::llround(static_cast<double>(n) / step);
    for (int64_t j = 0; j < outLen && ok; j += kBlock) {
      const int64_t m = std::min(kBlock, outLen - j);
      rs.process(fetch, j, j + m, buf.data());
      ok = w.write(buf.data(), static_cast<size_t>(m));
    }
  }
  ok = w.close(loop ? static_cast<uint64_t>(outLen) : 0) && ok;
  if (!ok || std::rename(tmp.c_str(), job.output.c_str()) != 0) {
    std::remove(tmp.c_str());
    return false;
  }
  return true;
}

double peakOf(const std::string& path, const int64_t* starts,
              const int64_t* ends, int32_t n) {
  auto src = MappedWav::open(path.c_str());
  if (!src) return -1.0;
  float peak = 0.0f;
  for (int32_t k = 0; k < n; ++k) {
    const int64_t a = std::clamp<int64_t>(starts[k], 0, src->frames);
    const int64_t b = std::clamp<int64_t>(ends[k], a, src->frames);
    for (int64_t i = a; i < b; ++i) peak = std::max(peak, std::fabs(src->at(i)));
  }
  return peak;
}

}  // namespace ps
