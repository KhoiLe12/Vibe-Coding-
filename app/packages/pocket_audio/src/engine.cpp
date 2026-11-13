// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// M0 audio engine: one output device playing the test tone.
// See wiki/components/audio-engine.md.

#include <atomic>
#include <mutex>

#include "pocket_audio.h"
#include "third_party/miniaudio/miniaudio.h"
#include "tone_generator.h"

namespace {

constexpr ma_uint32 kSampleRate = 48000;
constexpr ma_uint32 kChannels = 2;

struct Engine {
  ma_context context;
  ma_device device;
  ps::ToneGenerator tone;
  std::atomic<int64_t> callbacks{0};
  bool running = false;
};

Engine g_engine;
// Guards start/stop only. Never taken on the audio thread.
std::mutex g_controlMutex;

void dataCallback(ma_device* device, void* output, const void* /*input*/,
                  ma_uint32 frameCount) {
  auto* engine = static_cast<Engine*>(device->pUserData);
  engine->tone.render(static_cast<float*>(output), frameCount,
                      device->playback.channels, device->sampleRate);
  engine->callbacks.fetch_add(1, std::memory_order_relaxed);
}

}  // namespace

extern "C" {

const char* ps_version(void) {
  return "0.1.0 (miniaudio " MA_VERSION_STRING ")";
}

int32_t ps_engine_start(void) {
  std::lock_guard<std::mutex> lock(g_controlMutex);
  if (g_engine.running) return PS_ERROR_ALREADY_RUNNING;

  ma_context_config contextConfig = ma_context_config_init();
  // iOS: play even when the ring/silent switch is on. Recording (M1) will
  // switch this to play-and-record with measurement mode
  // (wiki/concepts/recording-diverse-material.md).
  contextConfig.coreaudio.sessionCategory = ma_ios_session_category_playback;
  if (ma_context_init(nullptr, 0, &contextConfig, &g_engine.context) !=
      MA_SUCCESS) {
    return PS_ERROR_DEVICE;
  }

  ma_device_config config = ma_device_config_init(ma_device_type_playback);
  config.playback.format = ma_format_f32;
  config.playback.channels = kChannels;
  config.sampleRate = kSampleRate;
  config.performanceProfile = ma_performance_profile_low_latency;
  config.dataCallback = dataCallback;
  config.pUserData = &g_engine;

  if (ma_device_init(&g_engine.context, &config, &g_engine.device) !=
      MA_SUCCESS) {
    ma_context_uninit(&g_engine.context);
    return PS_ERROR_DEVICE;
  }
  g_engine.callbacks.store(0, std::memory_order_relaxed);
  if (ma_device_start(&g_engine.device) != MA_SUCCESS) {
    ma_device_uninit(&g_engine.device);
    ma_context_uninit(&g_engine.context);
    return PS_ERROR_DEVICE;
  }
  g_engine.running = true;
  return PS_OK;
}

void ps_engine_stop(void) {
  std::lock_guard<std::mutex> lock(g_controlMutex);
  if (!g_engine.running) return;
  ma_device_uninit(&g_engine.device);
  ma_context_uninit(&g_engine.context);
  g_engine.running = false;
}

int32_t ps_engine_is_running(void) {
  std::lock_guard<std::mutex> lock(g_controlMutex);
  return g_engine.running ? 1 : 0;
}

int32_t ps_engine_sample_rate(void) {
  std::lock_guard<std::mutex> lock(g_controlMutex);
  return g_engine.running ? static_cast<int32_t>(g_engine.device.sampleRate)
                          : 0;
}

int64_t ps_engine_callback_count(void) {
  return g_engine.callbacks.load(std::memory_order_relaxed);
}

void ps_tone_set(double frequency_hz, float amplitude) {
  g_engine.tone.set(frequency_hz, amplitude);
}

void ps_tone_render_offline(float* out, int32_t frames, int32_t channels,
                            int32_t sample_rate, double frequency_hz,
                            float amplitude) {
  ps::ToneGenerator tone;
  tone.set(frequency_hz, amplitude);
  tone.render(out, static_cast<uint32_t>(frames),
              static_cast<uint32_t>(channels),
              static_cast<uint32_t>(sample_rate));
}

}  // extern "C"
