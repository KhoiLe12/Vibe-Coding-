// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

#ifndef POCKET_AUDIO_TONE_GENERATOR_H
#define POCKET_AUDIO_TONE_GENERATOR_H

#include <atomic>
#include <cmath>
#include <cstdint>

namespace ps {

// Sine generator for the M0 "hello tone".
//
// Real-time safe: render() does no allocation, locking or I/O. Parameters are
// published through atomics by any thread and picked up at the next render().
// Amplitude is slew-limited to at most full scale per kRampSeconds, so that
// start, stop and level changes never click (wiki/concepts/crossfades-and-clicks.md).
class ToneGenerator {
 public:
  static constexpr double kRampSeconds = 0.010;

  void set(double frequencyHz, float amplitude) {
    targetFrequency_.store(frequencyHz, std::memory_order_relaxed);
    targetAmplitude_.store(amplitude, std::memory_order_relaxed);
  }

  // Writes `frames` interleaved frames of `channels` samples into out.
  void render(float* out, uint32_t frames, uint32_t channels,
              uint32_t sampleRate) {
    const double frequency = targetFrequency_.load(std::memory_order_relaxed);
    const float target = targetAmplitude_.load(std::memory_order_relaxed);
    const double phaseStep = frequency / sampleRate;
    const float rampStep =
        static_cast<float>(1.0 / (kRampSeconds * sampleRate));

    for (uint32_t i = 0; i < frames; ++i) {
      if (amplitude_ < target) {
        amplitude_ = std::fmin(amplitude_ + rampStep, target);
      } else if (amplitude_ > target) {
        amplitude_ = std::fmax(amplitude_ - rampStep, target);
      }
      const float sample =
          amplitude_ * static_cast<float>(std::sin(kTwoPi * phase_));
      phase_ += phaseStep;
      phase_ -= std::floor(phase_);
      for (uint32_t c = 0; c < channels; ++c) {
        out[i * channels + c] = sample;
      }
    }
  }

 private:
  static constexpr double kTwoPi = 6.283185307179586476925286766559;

  std::atomic<double> targetFrequency_{440.0};
  std::atomic<float> targetAmplitude_{0.0f};
  // Audio-thread state.
  double phase_ = 0.0;
  float amplitude_ = 0.0f;
};

}  // namespace ps

#endif  // POCKET_AUDIO_TONE_GENERATOR_H
