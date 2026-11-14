// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Band-limited resampler (windowed sinc, Kaiser window), used for varispeed
// (wiki/concepts/varispeed.md) and for exporting at 44.1 kHz. Offline only:
// it pulls input in blocks from a fetch function, so any source works (a WAV
// range, an edit list, a loop that wraps around).
//
// Output frame j reads input position j * step. When step > 1 (speeding up /
// lowering the rate) the kernel's cutoff drops to 1 / step so nothing above
// the new Nyquist frequency folds back as aliasing.

#ifndef PS_RESAMPLER_H
#define PS_RESAMPLER_H

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace ps {

class SincResampler {
 public:
  static constexpr int kZeros = 16;   // zero crossings each side of the kernel
  static constexpr int kRes = 512;    // table entries per zero crossing
  static constexpr double kBeta = 8.0;  // Kaiser window: ~-80 dB side lobes
  static constexpr double kPi = 3.14159265358979323846;
  // Cutoff a little under Nyquist leaves room for the kernel's transition
  // band (it would otherwise alias just below the new Nyquist); 0.97 of
  // 22.05 kHz is still above hearing.
  static constexpr double kCutoff = 0.97;

  explicit SincResampler(double step)
      : step_(step), cutoff_(kCutoff * std::min(1.0, 1.0 / step)) {
    table_.resize(kZeros * kRes + 2);
    const double i0b = besselI0(kBeta);
    for (size_t i = 0; i < table_.size(); ++i) {
      const double x = static_cast<double>(i) / kRes;  // in zero crossings
      const double r = x / kZeros;
      const double w =
          r >= 1.0 ? 0.0 : besselI0(kBeta * std::sqrt(1.0 - r * r)) / i0b;
      const double s = x == 0.0 ? 1.0 : std::sin(kPi * x) / (kPi * x);
      table_[i] = static_cast<float>(s * w);
    }
    halfWidth_ = static_cast<int64_t>(std::ceil(kZeros / cutoff_)) + 1;
  }

  double step() const { return step_; }

  // Computes output frames [j0, j1) into out. fetch(a, n, buf) must fill
  // buf with input frames [a, a + n) (zeros outside the input, or whatever
  // the caller wants there, e.g. wrapped audio for a loop).
  template <class Fetch>
  void process(Fetch&& fetch, int64_t j0, int64_t j1, float* out) {
    if (j1 <= j0) return;
    const int64_t a = static_cast<int64_t>(std::floor(j0 * step_)) - halfWidth_;
    const int64_t b =
        static_cast<int64_t>(std::ceil((j1 - 1) * step_)) + halfWidth_ + 1;
    in_.resize(static_cast<size_t>(b - a));
    fetch(a, static_cast<int64_t>(in_.size()), in_.data());
    const float scale = static_cast<float>(cutoff_);
    const double tScale = cutoff_ * kRes;  // input frames → table index
    for (int64_t j = j0; j < j1; ++j) {
      const double x = j * step_;
      const int64_t lo = static_cast<int64_t>(std::floor(x)) - halfWidth_ + 1;
      const int64_t hi = static_cast<int64_t>(std::floor(x)) + halfWidth_;
      float acc = 0.0f;
      for (int64_t i = lo; i <= hi; ++i) {
        const double pos = std::fabs(x - static_cast<double>(i)) * tScale;
        const size_t k = static_cast<size_t>(pos);
        if (k + 1 >= table_.size()) continue;
        const float f = static_cast<float>(pos - static_cast<double>(k));
        const float h = table_[k] + (table_[k + 1] - table_[k]) * f;
        acc += in_[static_cast<size_t>(i - a)] * h;
      }
      out[j - j0] = acc * scale;
    }
  }

 private:
  static double besselI0(double x) {
    double sum = 1.0, term = 1.0;
    for (int k = 1; k < 50; ++k) {
      term *= (x / (2.0 * k)) * (x / (2.0 * k));
      sum += term;
      if (term < 1e-12 * sum) break;
    }
    return sum;
  }

  double step_, cutoff_;
  int64_t halfWidth_ = 0;  // input frames each side of the centre
  std::vector<float> table_;
  std::vector<float> in_;
};

}  // namespace ps

#endif  // PS_RESAMPLER_H
