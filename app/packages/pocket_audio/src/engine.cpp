// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Audio engine: one device, output-only or full duplex (mic + output).
// See wiki/components/audio-engine.md.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <thread>
#include <vector>
#include <mutex>

#include "dsp_processor.h"
#include "latency_probe.h"
#include "looper.h"
#include "platform.h"
#include "player.h"
#include "pocket_audio.h"
#include "recorder.h"
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
  std::atomic<int32_t> interruptions{0};
  bool running = false;
  bool withInput = false;
  bool raw = true;
};

Engine g_engine;
ps::Recorder g_recorder;
ps::Player g_player;
ps::LatencyProbe g_probe;
ps::DspProcessor g_dsp;
ps::Looper g_looper;
// Mic mode for the next start with input (iOS): raw = measurement mode.
std::atomic<bool> g_rawInput{true};
// Requested period (I/O buffer) size in frames; 0 = miniaudio's default.
std::atomic<int32_t> g_periodFrames{0};
// Guards start/stop/restart. Never taken on the audio thread.
std::mutex g_controlMutex;

void dataCallback(ma_device* device, void* output, const void* input,
                  ma_uint32 frameCount) {
  auto* engine = static_cast<Engine*>(device->pUserData);
  if (input != nullptr) {
    g_recorder.process(static_cast<const float*>(input), frameCount);
  }
  engine->tone.render(static_cast<float*>(output), frameCount,
                      device->playback.channels, device->sampleRate);
  g_player.render(static_cast<float*>(output), frameCount,
                  device->playback.channels);
  g_looper.process(static_cast<const float*>(input),
                   static_cast<float*>(output), frameCount,
                   device->playback.channels);
  g_probe.process(static_cast<const float*>(input),
                  static_cast<float*>(output), frameCount,
                  device->playback.channels);
  engine->callbacks.fetch_add(1, std::memory_order_relaxed);
}

// Called by miniaudio on the main thread (iOS). Core Audio stops the device
// when a phone call or another app interrupts; restart when it ends. A take
// in progress just has a gap and continues ("pause" by the OS).
void notificationCallback(const ma_device_notification* n) {
  if (n->type == ma_device_notification_type_interruption_began) {
    g_engine.interruptions.fetch_add(1);
    return;
  }
  if (n->type != ma_device_notification_type_interruption_ended) return;
  std::lock_guard<std::mutex> lock(g_controlMutex);
  if (!g_engine.running) return;
  ps::platform::activateSession(g_engine.withInput, g_engine.raw);
  ma_device_start(&g_engine.device);
}

ma_result initDevice(bool withInput, int presetAttempt) {
  ma_device_config config = ma_device_config_init(
      withInput ? ma_device_type_duplex : ma_device_type_playback);
  config.playback.format = ma_format_f32;
  config.playback.channels = kChannels;
  config.capture.format = ma_format_f32;
  config.capture.channels = 1;  // mono takes (d007)
  config.sampleRate = kSampleRate;
  config.performanceProfile = ma_performance_profile_low_latency;
  // On iOS miniaudio turns this into the session's preferred I/O buffer
  // duration, and the duplex bridge pads by 2 capture periods, so it drives
  // round-trip latency directly (wiki/concepts/audio-latency.md).
  config.periodSizeInFrames = static_cast<ma_uint32>(g_periodFrames.load());
  config.dataCallback = dataCallback;
  config.notificationCallback = notificationCallback;
  config.pUserData = &g_engine;
  // Android: raw mic first; some phones only offer voice recognition, which
  // is the next least processed preset.
  config.aaudio.usage = ma_aaudio_usage_media;
  if (presetAttempt == 0) {
    config.aaudio.inputPreset = ma_aaudio_input_preset_unprocessed;
    config.opensl.recordingPreset = ma_opensl_recording_preset_voice_unprocessed;
  } else {
    config.aaudio.inputPreset = ma_aaudio_input_preset_voice_recognition;
    config.opensl.recordingPreset = ma_opensl_recording_preset_voice_recognition;
  }
  return ma_device_init(&g_engine.context, &config, &g_engine.device);
}

}  // namespace

extern "C" {

const char* ps_version(void) {
  return "0.2.0 (miniaudio " MA_VERSION_STRING ")";
}

int32_t ps_engine_start_ex(int32_t with_input) {
  std::lock_guard<std::mutex> lock(g_controlMutex);
  if (g_engine.running) return PS_ERROR_ALREADY_RUNNING;
  const bool withInput = with_input != 0;
  if (withInput && ps::platform::micPermission() != PS_MIC_GRANTED) {
    return PS_ERROR_NO_PERMISSION;
  }
  const bool raw = g_rawInput.load();
  if (!ps::platform::activateSession(withInput, raw)) return PS_ERROR_DEVICE;

  ma_context_config contextConfig = ma_context_config_init();
  // iOS: the session is configured in platform_apple.mm; miniaudio must not
  // override the category/mode or (de)activate it.
  contextConfig.coreaudio.sessionCategory = ma_ios_session_category_none;
  contextConfig.coreaudio.noAudioSessionActivate = MA_TRUE;
  contextConfig.coreaudio.noAudioSessionDeactivate = MA_TRUE;
  if (ma_context_init(nullptr, 0, &contextConfig, &g_engine.context) !=
      MA_SUCCESS) {
    return PS_ERROR_DEVICE;
  }

  ma_result r = initDevice(withInput, 0);
  if (r != MA_SUCCESS && withInput) r = initDevice(withInput, 1);
  if (r != MA_SUCCESS) {
    ma_context_uninit(&g_engine.context);
    return PS_ERROR_DEVICE;
  }
  g_engine.callbacks.store(0, std::memory_order_relaxed);
  if (ma_device_start(&g_engine.device) != MA_SUCCESS) {
    ma_device_uninit(&g_engine.device);
    ma_context_uninit(&g_engine.context);
    return PS_ERROR_DEVICE;
  }
  g_engine.withInput = withInput;
  g_engine.raw = raw;
  g_engine.running = true;
  return PS_OK;
}

int32_t ps_engine_start(void) { return ps_engine_start_ex(0); }

void ps_engine_stop(void) {
  std::lock_guard<std::mutex> lock(g_controlMutex);
  if (!g_engine.running) return;
  ma_device_uninit(&g_engine.device);
  ma_context_uninit(&g_engine.context);
  ps::platform::deactivateSession();
  g_engine.running = false;
  g_engine.withInput = false;
}

int32_t ps_engine_is_running(void) {
  std::lock_guard<std::mutex> lock(g_controlMutex);
  return g_engine.running ? 1 : 0;
}

int32_t ps_engine_has_input(void) {
  std::lock_guard<std::mutex> lock(g_controlMutex);
  return g_engine.running && g_engine.withInput ? 1 : 0;
}

int32_t ps_engine_sample_rate(void) {
  std::lock_guard<std::mutex> lock(g_controlMutex);
  return g_engine.running ? static_cast<int32_t>(g_engine.device.sampleRate)
                          : 0;
}

void ps_engine_set_raw_input(int32_t raw) { g_rawInput.store(raw != 0); }

void ps_engine_set_period_frames(int32_t frames) {
  g_periodFrames.store(frames < 0 ? 0 : frames);
}

int32_t ps_engine_buffer_info(int32_t* out_values) {
  std::lock_guard<std::mutex> lock(g_controlMutex);
  if (!out_values || !g_engine.running) return 0;
  const ma_device& d = g_engine.device;
  out_values[0] = static_cast<int32_t>(d.playback.internalPeriodSizeInFrames);
  out_values[1] = static_cast<int32_t>(d.playback.internalPeriods);
  out_values[2] = g_engine.withInput
                      ? static_cast<int32_t>(d.capture.internalPeriodSizeInFrames)
                      : 0;
  out_values[3] =
      g_engine.withInput ? static_cast<int32_t>(d.capture.internalPeriods) : 0;
  out_values[4] = static_cast<int32_t>(d.playback.internalSampleRate);
  return 1;
}

int64_t ps_engine_callback_count(void) {
  return g_engine.callbacks.load(std::memory_order_relaxed);
}

int32_t ps_engine_interruption_count(void) {
  return g_engine.interruptions.load();
}

int32_t ps_mic_permission(void) { return ps::platform::micPermission(); }

void ps_mic_request_permission(void) { ps::platform::requestMicPermission(); }

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

// ---- Recorder ----

int32_t ps_peaks_block_frames(void) {
  return static_cast<int32_t>(ps::Recorder::kPeakBlock);
}

void ps_input_process(const float* mono, int32_t frames) {
  if (frames > 0) g_recorder.process(mono, static_cast<uint32_t>(frames));
}

void ps_input_set_gain(float linear_gain) { g_recorder.setGain(linear_gain); }

float ps_input_take_peak_level(void) { return g_recorder.takePeakLevel(); }

int32_t ps_input_clipped(void) { return g_recorder.clipped() ? 1 : 0; }

void ps_input_reset_clip(void) { g_recorder.resetClip(); }

int32_t ps_recorder_begin(const char* wav_path, int32_t sample_rate) {
  if (!wav_path || sample_rate <= 0) return PS_ERROR_FILE;
  return g_recorder.begin(wav_path, static_cast<uint32_t>(sample_rate));
}

int32_t ps_recorder_end(const char* peaks_path) {
  return g_recorder.end(peaks_path);
}

void ps_recorder_set_paused(int32_t paused) {
  g_recorder.setPaused(paused != 0);
}

int32_t ps_recorder_is_paused(void) { return g_recorder.paused() ? 1 : 0; }

int32_t ps_recorder_is_recording(void) {
  return g_recorder.recording() ? 1 : 0;
}

int64_t ps_recorder_frames_written(void) { return g_recorder.framesWritten(); }

int64_t ps_recorder_dropped_frames(void) { return g_recorder.droppedFrames(); }

int32_t ps_recorder_write_error(void) {
  return g_recorder.writeError() ? 1 : 0;
}

int32_t ps_recorder_copy_peaks(float* out, int32_t first_block,
                               int32_t max_blocks) {
  if (!out) return 0;
  return g_recorder.copyPeaks(out, first_block, max_blocks);
}

int32_t ps_recorder_peak_block_count(void) {
  return g_recorder.peakBlockCount();
}

// ---- Player ----

int32_t ps_player_open(const char* wav_path) {
  return wav_path ? g_player.open(wav_path) : PS_ERROR_FILE;
}
void ps_player_close(void) { g_player.close(); }
void ps_player_set_playing(int32_t playing) { g_player.setPlaying(playing != 0); }
int32_t ps_player_is_playing(void) { return g_player.playing() ? 1 : 0; }
int32_t ps_player_finished(void) { return g_player.finished() ? 1 : 0; }
int32_t ps_player_seek(int64_t frame) { return g_player.seek(frame); }
int64_t ps_player_position(void) { return g_player.position(); }
int64_t ps_player_length(void) { return g_player.length(); }

int64_t ps_player_set_clips(const int64_t* src_starts, const int64_t* src_ends,
                            const float* gains, int32_t count) {
  if (count > 0 && (!src_starts || !src_ends)) return -1;
  return g_player.setClips(nullptr, src_starts, src_ends, gains, count);
}

int64_t ps_player_set_source_clips(const char* source_path,
                                   const int64_t* src_starts,
                                   const int64_t* src_ends, const float* gains,
                                   int32_t count) {
  if (count > 0 && (!src_starts || !src_ends)) return -1;
  return g_player.setClips(source_path, src_starts, src_ends, gains, count);
}

int64_t ps_player_zero_crossing(int64_t src_frame, int32_t radius) {
  return g_player.zeroCrossing(src_frame, radius);
}

void ps_player_set_loop(int64_t start, int64_t end) {
  g_player.setLoop(start, end);
}
int64_t ps_player_loop_start(void) { return g_player.loopStart(); }
int64_t ps_player_loop_end(void) { return g_player.loopEnd(); }

void ps_player_begin_scrub(void) { g_player.beginScrub(); }
void ps_player_set_scrub_target(double frame) {
  g_player.setScrubTarget(frame);
}
void ps_player_set_shuttle(double speed) { g_player.setShuttle(speed); }
void ps_player_end_scrub(void) { g_player.endScrub(); }
int32_t ps_player_is_scrubbing(void) { return g_player.scrubbing() ? 1 : 0; }

void ps_player_render_offline(float* out, int32_t frames, int32_t channels) {
  if (!out || frames <= 0 || channels <= 0) return;
  std::fill(out, out + static_cast<size_t>(frames) * channels, 0.0f);
  g_player.renderForTest(out, static_cast<uint32_t>(frames),
                         static_cast<uint32_t>(channels));
}

int32_t ps_peaks_build(const char* wav_path, const char* peaks_path) {
  if (!wav_path || !peaks_path) return PS_ERROR_FILE;
  return ps::buildPeaksFromWav(wav_path, peaks_path, ps::Recorder::kPeakBlock)
             ? PS_OK
             : PS_ERROR_FILE;
}

// ---- Latency probe (M2 gate) ----

void ps_latency_start(int32_t interval_ms) {
  const uint32_t sr = kSampleRate;
  g_probe.start(sr, static_cast<uint32_t>(std::max(0, interval_ms)) * sr / 1000);
}
void ps_latency_stop(void) { g_probe.stop(); }
int32_t ps_latency_is_running(void) { return g_probe.active() ? 1 : 0; }
int32_t ps_latency_count(void) { return g_probe.count(); }
int32_t ps_latency_missed(void) { return g_probe.missed(); }
int32_t ps_latency_input_overflow(void) {
  return g_probe.inputOverflow() ? 1 : 0;
}
int32_t ps_latency_copy_ms(float* out, int32_t first, int32_t max) {
  return out ? g_probe.copyResults(out, first, max) : 0;
}

int32_t ps_latency_reported(double* input_s, double* output_s,
                            double* io_buffer_s) {
  if (!input_s || !output_s || !io_buffer_s) return 0;
  return ps::platform::reportedLatency(input_s, output_s, io_buffer_s) ? 1 : 0;
}

void ps_latency_simulate(int32_t delay_frames, int32_t seconds,
                         float echo_gain, float noise_amp) {
  // A fake room: whatever the probe plays comes back delay_frames later,
  // scaled by echo_gain, plus white noise. Drives the probe's audio-thread
  // code exactly as a 256-frame duplex callback would.
  constexpr uint32_t kBlock = 256;
  const uint32_t sr = kSampleRate;
  g_probe.start(sr, sr / 2);
  const size_t total = static_cast<size_t>(seconds) * sr;
  std::vector<float> outHistory(total + kBlock, 0.0f);
  std::vector<float> in(kBlock), out(kBlock);
  uint32_t noise = 12345;
  for (size_t pos = 0; pos + kBlock <= total; pos += kBlock) {
    for (uint32_t i = 0; i < kBlock; ++i) {
      const int64_t src = static_cast<int64_t>(pos + i) - delay_frames;
      noise = noise * 1664525u + 1013904223u;
      const float n = noise_amp * ((noise >> 8) / 8388608.0f - 1.0f);
      in[i] = (src >= 0 ? echo_gain * outHistory[static_cast<size_t>(src)] : 0) + n;
    }
    std::fill(out.begin(), out.end(), 0.0f);
    g_probe.process(in.data(), out.data(), kBlock, 1);
    std::copy(out.begin(), out.end(), outHistory.begin() + pos);
    // Faster than real time, but never faster than the analysis thread
    // drains its input (a real device delivers input in real time).
    while (g_probe.inputBacklog() > sr) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  }
  // Give the analysis thread time to finish, then stop (results are kept).
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  g_probe.stop();
}

// ---- DSP processor (M4) ----

int32_t ps_render_start(const char* input, int64_t start, int64_t end,
                        const char* output, double semitones, double tempo,
                        int32_t formant) {
  if (!input || !output) return -1;
  ps::RenderJob job;
  job.input = input;
  job.start = start;
  job.end = end;
  job.output = output;
  job.semitones = semitones;
  job.tempo = tempo;
  job.formant = formant != 0;
  return g_dsp.start(job);
}

void ps_render_cancel(void) { g_dsp.cancel(); }
int32_t ps_render_job(void) { return g_dsp.jobId(); }
int32_t ps_render_state(void) { return g_dsp.state(); }
double ps_render_progress(void) { return g_dsp.progress(); }

// ---- Looper (M5a) ----

void ps_looper_enable(int32_t on) {
  if (on) g_looper.enable(); else g_looper.disable();
}
int32_t ps_looper_enabled(void) { return g_looper.enabled() ? 1 : 0; }
void ps_looper_press(void) { g_looper.press(); }
void ps_looper_stop(void) { g_looper.stop(); }
void ps_looper_play(void) { g_looper.play(); }
void ps_looper_clear(void) { g_looper.clear(); }
void ps_looper_undo(void) { g_looper.undo(); }
void ps_looper_redo(void) { g_looper.redo(); }
void ps_looper_delete_layer(int32_t layer) { g_looper.deleteLayer(layer); }
void ps_looper_set_latency(int32_t frames) { g_looper.setLatency(frames); }
void ps_looper_set_layer_gain(int32_t layer, float gain) {
  g_looper.setLayerGain(layer, gain);
}
int32_t ps_looper_state(void) { return g_looper.state(); }
int64_t ps_looper_length(void) { return g_looper.loopLength(); }
int64_t ps_looper_position(void) { return g_looper.position(); }
int32_t ps_looper_layers(void) { return g_looper.layers(); }
int32_t ps_looper_redoable(void) { return g_looper.redoable(); }
int32_t ps_looper_starved(void) { return g_looper.overdubStarved() ? 1 : 0; }
float ps_looper_take_input_peak(void) { return g_looper.takeInputPeak(); }
float ps_looper_take_output_peak(void) { return g_looper.takeOutputPeak(); }
void ps_looper_set_input_gain(float g) { g_looper.setInputGain(g); }
void ps_looper_set_output_gain(float g) { g_looper.setOutputGain(g); }
int32_t ps_looper_clipped(void) { return g_looper.clipped() ? 1 : 0; }
void ps_looper_reset_clip(void) { g_looper.resetClip(); }
int32_t ps_looper_bounce(const char* path, int32_t passes) {
  return path && g_looper.bounce(path, passes) ? PS_OK : PS_ERROR_FILE;
}
void ps_looper_process_offline(const float* in, float* out, int32_t frames,
                               int32_t channels) {
  if (!out || frames <= 0 || channels <= 0) return;
  std::fill(out, out + static_cast<size_t>(frames) * channels, 0.0f);
  g_looper.process(in, out, static_cast<uint32_t>(frames),
                   static_cast<uint32_t>(channels));
}
void ps_looper_service(void) { g_looper.serviceOnce(); }

const char* ps_output_route(void) { return ps::platform::outputRoute(); }

}  // extern "C"
