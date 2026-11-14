// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

#include "looper.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "wav_writer.h"

namespace ps {
namespace {

constexpr float kGainStep = 1.0f / Looper::kFadeFrames;

// Gentle limiter: transparent below 0.8, approaches ±1 smoothly above.
inline float softLimit(float y) {
  const float a = std::fabs(y);
  if (a <= 0.8f) return y;
  const float limited = 0.8f + 0.2f * std::tanh((a - 0.8f) / 0.2f);
  return y < 0.0f ? -limited : limited;
}

// One-pole gain smoothing, time constant ~40 ms at 48 kHz; snaps when
// within 0.01 % so unity stays exact.
inline void smooth(float& g, float target) {
  g += (target - g) * (1.0f / 1920.0f);
  if (std::fabs(target - g) < 1e-4f * std::fabs(target) + 1e-7f) g = target;
}

// Moves g toward target by at most `step` (click-free gain changes).
inline void approach(float& g, float target, float step) {
  if (g < target) g = std::min(target, g + step);
  else if (g > target) g = std::max(target, g - step);
}
constexpr float kHalfPi = 1.57079632679f;

}  // namespace

Looper::Looper() {
  for (auto& g : gainTarget_) g.store(1.0f);
}

Looper::~Looper() { disable(); }

void Looper::enable() {
  if (enabled_.load()) return;
  base_.reset(new float[kMaxLoopFrames + kSeamFrames]());
  state_.store(kIdle);
  loopLen_.store(0);
  position_.store(0);
  activeLayers_.store(0);
  redoLayers_.store(0);
  stack_ = active_ = 0;
  len_ = pos_ = recPos_ = 0;
  cur_ = nullptr;
  // Every piece of audio-thread state starts clean: a fade or recording
  // left over from an earlier session could point past a shorter new loop.
  jumpLeft_ = 0;
  jumpFrom_ = 0;
  recLeft_ = 0;
  seamTail_ = 0;
  seamLeft_ = 0;
  inputGain_ = inputGainTarget_.load();  // no ramp left over from before
  outputGain_ = outputGainTarget_.load();
  for (auto& g : gainTarget_) g.store(1.0f);
  std::fill(std::begin(layerGain_), std::end(layerGain_), 0.0f);
  std::fill(std::begin(deleting_), std::end(deleting_), false);
  stopService_.store(false);
  service_ = std::thread(&Looper::serviceLoop, this);
  enabled_.store(true);
}

void Looper::disable() {
  if (!enabled_.load()) return;
  enabled_.store(false);
  while (inProcess_.load() != 0) std::this_thread::yield();
  stopService_.store(true);
  if (service_.joinable()) service_.join();
  // Free everything (audio thread is out).
  for (int i = 1; i < kMaxLayers; ++i) {
    std::free(layerBuf_[i]);
    layerBuf_[i] = nullptr;
  }
  layerBuf_[0] = nullptr;
  std::free(cur_);
  cur_ = nullptr;
  Buffer b;
  while (ready_.pop(b)) std::free(b.data);
  float* p;
  while (retired_.pop(p)) std::free(p);
  base_.reset();
}

void Looper::press() { commands_.push(kPress); }
void Looper::stop() { commands_.push(kStop); }
void Looper::play() { commands_.push(kPlay); }
void Looper::clear() { commands_.push(kClear); }
void Looper::undo() { commands_.push(kUndo); }
void Looper::redo() { commands_.push(kRedo); }
void Looper::deleteLayer(int32_t layer) {
  if (layer >= 1 && layer < kMaxLayers) commands_.push(kDelete | (layer << 8));
}

void Looper::removeLayer(int32_t i) {
  if (layerBuf_[i]) retired_.push(layerBuf_[i]);
  for (int32_t k = i; k + 1 < stack_; ++k) {
    layerBuf_[k] = layerBuf_[k + 1];
    layerGain_[k] = layerGain_[k + 1];
    deleting_[k] = deleting_[k + 1];
    gainTarget_[k].store(gainTarget_[k + 1].load());
  }
  --stack_;
  layerBuf_[stack_] = nullptr;
  layerGain_[stack_] = 0.0f;
  deleting_[stack_] = false;
  gainTarget_[stack_].store(1.0f);
  if (i < active_) --active_;
}

void Looper::setLayerGain(int32_t layer, float gain) {
  if (layer >= 0 && layer < kMaxLayers) gainTarget_[layer].store(gain);
}

float* Looper::takeBuffer() {
  Buffer b;
  while (ready_.pop(b)) {
    if (b.frames == len_) return b.data;
    retired_.push(b.data);  // made for another loop length
  }
  return nullptr;
}

void Looper::retireAbove(int32_t keep) {
  for (int32_t i = std::max(keep, 1); i < stack_; ++i) {
    if (layerBuf_[i]) retired_.push(layerBuf_[i]);
    layerBuf_[i] = nullptr;
  }
  stack_ = std::min(stack_, keep);
}

void Looper::finishLayer() {
  if (!cur_) return;
  // Recording a new layer drops anything that was undone (no redo past it).
  retireAbove(active_);
  if (stack_ < kMaxLayers) {
    layerBuf_[stack_] = cur_;
    layerGain_[stack_] = 0.0f;  // ramps in
    ++stack_;
    active_ = stack_;
  } else {
    retired_.push(cur_);  // full: drop the layer
  }
  cur_ = nullptr;
}

void Looper::cancelOverdub() {
  if (cur_) retired_.push(cur_);  // discard the partial layer
  cur_ = nullptr;
}

void Looper::handle(Cmd c, int32_t arg) {
  const int32_t s = state_.load();
  switch (c) {
    case kPress:
      if (s == kIdle) {
        recPos_ = 0;
        state_.store(kRecording);
      } else if (s == kRecording) {
        // Close: loop length = what was played; record a 10 ms tail for
        // the seam crossfade, then start playing.
        len_ = std::max<int64_t>(recPos_, kSeamFrames * 2);
        seamLeft_ = kSeamFrames;
        state_.store(kClosing);
      } else if (s == kPlaying || s == kStopped) {
        // Restart the loop from the top now, so the layer starts with the
        // first take; recording begins when the write position (one round
        // trip behind) reaches the loop start, and covers exactly one pass.
        cur_ = takeBuffer();
        if (!cur_) {
          starved_.store(true);
          break;
        }
        starved_.store(false);
        if (s == kPlaying && pos_ != 0) {
          jumpFrom_ = pos_;  // fade the old position out: no click
          jumpLeft_ = kFadeFrames;
        }
        pos_ = 0;
        state_.store(kArmed);
      } else if (s == kArmed || s == kOverdubbing) {
        cancelOverdub();
        state_.store(kPlaying);
      }
      break;
    case kStop:
      if (s == kArmed || s == kOverdubbing) cancelOverdub();
      if (s == kPlaying || s == kArmed || s == kOverdubbing) {
        state_.store(kStopped);
      }
      if (s == kRecording) {  // stop while recording = close, then stop
        handle(kPress);
      }
      break;
    case kPlay:
      if (s == kStopped) {
        pos_ = 0;
        state_.store(kPlaying);
      }
      break;
    case kClear:
      jumpLeft_ = 0;
      if (cur_) {
        retired_.push(cur_);
        cur_ = nullptr;
      }
      for (int32_t i = 1; i < stack_; ++i) {
        if (layerBuf_[i]) retired_.push(layerBuf_[i]);
        layerBuf_[i] = nullptr;
      }
      layerBuf_[0] = nullptr;
      std::fill(std::begin(deleting_), std::end(deleting_), false);
      stack_ = active_ = 0;
      len_ = pos_ = recPos_ = 0;
      loopLen_.store(0);
      position_.store(0);
      state_.store(kIdle);
      break;
    case kUndo:
      if (s != kOverdubbing && s != kArmed && active_ > 1) --active_;
      break;
    case kRedo:
      if (s != kOverdubbing && s != kArmed && active_ < stack_) ++active_;
      break;
    case kDelete:
      // Only audible overdub layers; never while one is being recorded.
      if (s != kOverdubbing && s != kArmed && arg >= 1 && arg < active_) {
        deleting_[arg] = true;  // fades out, then removeLayer()
      }
      break;
  }
}

void Looper::process(const float* in, float* out, uint32_t frames,
                     uint32_t channels) {
  inProcess_.fetch_add(1);
  if (!enabled_.load()) {
    inProcess_.fetch_sub(1);
    return;
  }
  int32_t c;
  while (commands_.pop(c)) handle(static_cast<Cmd>(c & 0xff), c >> 8);

  const int64_t L = latency_.load(std::memory_order_relaxed);
  float outPeak = 0.0f, peak = 0.0f;
  bool clip = false;
  const float inTarget = inputGainTarget_.load(std::memory_order_relaxed);
  const float outTarget = outputGainTarget_.load(std::memory_order_relaxed);
  for (uint32_t i = 0; i < frames; ++i) {
    // One-pole smoothing (~40 ms whatever the size of the change; a
    // fixed-rate ramp took a full second to come down from +26 dB).
    smooth(inputGain_, inTarget);
    smooth(outputGain_, outTarget);
    const float x = in ? in[i] * inputGain_ : 0.0f;
    peak = std::max(peak, std::fabs(x));
    clip = clip || std::fabs(x) >= 1.0f;
    const int32_t s = state_.load(std::memory_order_relaxed);

    if (s == kRecording) {
      base_[recPos_++] = x;
      position_.store(recPos_, std::memory_order_relaxed);
      if (recPos_ >= kMaxLoopFrames) handle(kPress);  // auto-close at 60 s
      continue;
    }
    if (s == kClosing) {
      base_[recPos_++] = x;
      if (--seamLeft_ == 0) {
        // Equal-power crossfade of the tail (recorded after "close") into
        // the head, so the loop restart is seamless.
        for (uint32_t k = 0; k < kSeamFrames; ++k) {
          const float u = (k + 0.5f) / kSeamFrames;
          base_[k] = base_[k] * std::sin(u * kHalfPi) +
                     base_[len_ + k] * std::cos(u * kHalfPi);
        }
        // Buffers prepared for an earlier loop length are useless now; hand
        // them back so the service thread refills with the right size.
        Buffer stale;
        while (ready_.pop(stale)) retired_.push(stale.data);
        layerBuf_[0] = base_.get();
        layerGain_[0] = 1.0f;
        jumpLeft_ = 0;  // nothing from an earlier loop may fade in
        stack_ = active_ = 1;
        pos_ = 0;
        loopLen_.store(len_);
        state_.store(kPlaying);
      }
      continue;
    }
    if (s != kPlaying && s != kOverdubbing && s != kArmed) continue;

    // Playback mix of the layer stack.
    float y = 0.0f, yOld = 0.0f;
    for (int32_t k = 0; k < stack_; ++k) {
      const float target = k < active_ && !deleting_[k]
                               ? gainTarget_[k].load(std::memory_order_relaxed)
                               : 0.0f;
      float& g = layerGain_[k];
      if (g < target) g = std::min(target, g + kGainStep);
      else if (g > target) g = std::max(target, g - kGainStep);
      if (g != 0.0f) {
        y += layerBuf_[k][pos_] * g;
        if (jumpLeft_ > 0) yOld += layerBuf_[k][jumpFrom_] * g;
      }
    }
    if (jumpLeft_ > 0) {
      // Crossfade from the old position into the restart.
      const float w = static_cast<float>(jumpLeft_) / kFadeFrames;
      y = y * (1.0f - w) + yOld * w;
      if (++jumpFrom_ >= len_) jumpFrom_ = 0;
      --jumpLeft_;
    }
    const float heard = softLimit(y * outputGain_);
    for (uint32_t ch = 0; ch < channels; ++ch) out[i * channels + ch] += heard;
    outPeak = std::max(outPeak, std::fabs(heard));

    // Overdub: write where the performer heard it (one round trip ago).
    if ((s == kArmed || s == kOverdubbing) && cur_) {
      const int64_t q = ((pos_ - L) % len_ + len_) % len_;
      int32_t st = s;
      if (st == kArmed && q == 0) {
        st = kOverdubbing;  // the write position is at the loop start
        recLeft_ = len_;
        seamTail_ = kSeamFrames;
        state_.store(kOverdubbing);
      }
      if (st == kOverdubbing) {
        if (recLeft_ > 0) {
          cur_[q] = x;
          --recLeft_;
        } else {
          // One pass done. Like the first take's seam, record 10 ms more
          // and crossfade it into the layer's head (equal power), so the
          // layer is seamless at the loop point.
          const uint32_t k = kSeamFrames - seamTail_;
          const float u = (k + 0.5f) / kSeamFrames;
          cur_[q] = cur_[q] * std::sin(u * kHalfPi) + x * std::cos(u * kHalfPi);
          if (--seamTail_ == 0) {
            finishLayer();
            state_.store(kPlaying);
          }
        }
      }
    }

    if (++pos_ >= len_) pos_ = 0;
  }

  // Layers being deleted are removed once their fade-out has finished.
  for (int32_t k = stack_ - 1; k >= 1; --k) {
    if (deleting_[k] && layerGain_[k] == 0.0f) removeLayer(k);
  }

  float prevPeak = inputPeak_.load(std::memory_order_relaxed);
  while (peak > prevPeak &&
         !inputPeak_.compare_exchange_weak(prevPeak, peak)) {
  }
  if (clip) clipped_.store(true, std::memory_order_relaxed);
  float prevOut = outputPeak_.load(std::memory_order_relaxed);
  while (outPeak > prevOut &&
         !outputPeak_.compare_exchange_weak(prevOut, outPeak)) {
  }
  const int32_t st = state_.load(std::memory_order_relaxed);
  if (st == kPlaying || st == kOverdubbing) {
    position_.store(pos_, std::memory_order_relaxed);
  }
  activeLayers_.store(active_, std::memory_order_relaxed);
  redoLayers_.store(stack_ - active_, std::memory_order_relaxed);
  inProcess_.fetch_sub(1);
}

void Looper::serviceOnce() {
  float* p;
  while (retired_.pop(p)) std::free(p);
  const int64_t len = loopLen_.load();
  if (len <= 0) return;
  while (ready_.size() < 3) {
    Buffer b{static_cast<float*>(std::calloc(static_cast<size_t>(len), sizeof(float))), len};
    if (!b.data || !ready_.push(b)) {
      std::free(b.data);
      break;
    }
  }
}

void Looper::serviceLoop() {
  while (!stopService_.load()) {
    serviceOnce();
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
}

bool Looper::bounce(const char* path, int32_t passes) {
  const int32_t s = state_.load();
  if (s != kPlaying && s != kStopped) return false;
  const int64_t len = loopLen_.load();
  if (len <= 0 || passes < 1) return false;
  // Layers below the audible stack are immutable while not overdubbing.
  const int32_t n = activeLayers_.load();
  std::vector<float> mix(static_cast<size_t>(len), 0.0f);
  for (int32_t k = 0; k < n; ++k) {
    const float* b = layerBuf_[k];
    const float g = gainTarget_[k].load();
    if (!b || g == 0.0f) continue;
    for (int64_t i = 0; i < len; ++i) mix[static_cast<size_t>(i)] += b[i] * g;
  }
  WavWriter w;
  if (!w.open(path, 48000)) return false;
  for (int32_t p = 0; p < passes; ++p) {
    if (!w.write(mix.data(), mix.size())) {
      w.close();
      return false;
    }
  }
  return w.close();
}

}  // namespace ps
