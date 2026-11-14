// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Loop pedal engine (wiki/features/loop-pedal.md, wiki/decisions/
// d005-loop-engine.md, d014-looper-m5a.md). Everything timing-critical runs
// in process() on the audio thread; control calls only enqueue commands
// (lock-free) or set atomics. A service thread prepares zeroed layer buffers
// and frees retired ones, so the audio thread never allocates or frees.
//
// Flow (main button): Idle → Recording → (close) → Playing → Overdubbing →
// (one full pass) → Playing. Pressing Overdub restarts the loop from the top
// at once (5 ms crossfade) and records exactly one pass, so every layer
// starts together with the first take (human, 2026-11-14). The few ms until
// the performance reaches the mic (one round trip) are the brief "Armed"
// state. Pressing again while Armed/Overdubbing cancels.
// Overdubs are latency-compensated: an input sample is written at loop
// position p − L, where p is the loop position of the output frame in the
// same callback and L the calibrated round trip (latency-compensation.md).
// Recording starts when that write position reaches the loop start.

#ifndef PS_LOOPER_H
#define PS_LOOPER_H

#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <thread>

namespace ps {

// Fixed-size lock-free single-producer/single-consumer queue.
template <typename T, size_t N>
class SpscQueue {
 public:
  bool push(const T& v) {
    const size_t h = head_.load(std::memory_order_relaxed);
    if (h - tail_.load(std::memory_order_acquire) == N) return false;
    items_[h % N] = v;
    head_.store(h + 1, std::memory_order_release);
    return true;
  }
  bool pop(T& v) {
    const size_t t = tail_.load(std::memory_order_relaxed);
    if (t == head_.load(std::memory_order_acquire)) return false;
    v = items_[t % N];
    tail_.store(t + 1, std::memory_order_release);
    return true;
  }
  size_t size() const {
    return head_.load(std::memory_order_acquire) -
           tail_.load(std::memory_order_acquire);
  }

 private:
  std::array<T, N> items_{};
  std::atomic<size_t> head_{0}, tail_{0};
};

class Looper {
 public:
  static constexpr int64_t kMaxLoopFrames = 60 * 48000;  // 60 s
  static constexpr int kMaxLayers = 32;  // including the base take
  static constexpr uint32_t kFadeFrames = 240;        // 5 ms
  static constexpr uint32_t kSeamFrames = 480;        // 10 ms loop seam

  enum State : int32_t {
    kIdle = 0,         // nothing recorded
    kRecording = 1,    // first take, sets the loop length
    kClosing = 2,      // recording the 10 ms seam tail after "close"
    kPlaying = 3,
    kOverdubbing = 4,
    kStopped = 5,      // loop exists, not playing
    kArmed = 6,        // overdub waits for the loop start
  };

  Looper();
  ~Looper();

  // ---- audio thread ----
  // in: mono mic input (may be null); out: interleaved, added to.
  void process(const float* in, float* out, uint32_t frames,
               uint32_t channels);

  // ---- control (one control thread) ----
  void enable();   // starts the service thread; allocates the base buffer
  void disable();  // stops it; frees everything
  bool enabled() const { return enabled_.load(); }

  void press();  // main button: record / close / overdub on/off
  void stop();
  void play();
  void clear();
  void undo();
  void redo();
  // Removes overdub layer i (1 ≤ i < layers(); the first take stays). It
  // fades out over 5 ms first; layers above it move down one index.
  void deleteLayer(int32_t layer);
  void setLatency(int32_t frames) { latency_.store(frames < 0 ? 0 : frames); }
  int32_t latency() const { return latency_.load(); }
  // Mic gain for everything the loop records (linear; smoothed).
  void setInputGain(float g) { inputGainTarget_.store(g); }
  // Playback volume of the loop (linear; smoothed). Playback only: not
  // recorded, not bounced. Peaks above ~0.8 are soft-limited.
  void setOutputGain(float g) { outputGainTarget_.store(g); }
  bool clipped() const { return clipped_.load(); }
  void resetClip() { clipped_.store(false); }
  // Effective linear gain of layer i (0 = base take), after mute/solo.
  void setLayerGain(int32_t layer, float gain);

  // Status (any thread).
  State state() const { return static_cast<State>(state_.load()); }
  int64_t loopLength() const { return loopLen_.load(); }
  int64_t position() const { return position_.load(); }
  int32_t layers() const { return activeLayers_.load(); }   // audible stack
  int32_t redoable() const { return redoLayers_.load(); }
  bool overdubStarved() const { return starved_.load(); }
  // Peak of the last block of mic input (for a meter).
  float takeInputPeak() { return inputPeak_.exchange(0.0f); }
  // Peak of what the loop played since the last call (for a meter).
  float takeOutputPeak() { return outputPeak_.exchange(0.0f); }

  // Mixes the audible layers × passes into a mono float WAV (control thread;
  // only while Playing or Stopped). Returns false on error or wrong state.
  bool bounce(const char* path, int32_t passes);

  // Tests: run the service step synchronously.
  void serviceOnce();

 private:
  // Commands are queued as (cmd | arg << 8).
  enum Cmd : int32_t { kPress, kStop, kPlay, kClear, kUndo, kRedo, kDelete };

  void handle(Cmd c, int32_t arg = 0);
  void removeLayer(int32_t i);  // audio thread, once it has faded out
  void finishLayer();      // audio thread: current overdub layer → stack
  void cancelOverdub();    // audio thread: drop the overdub in progress
  void retireAbove(int32_t keep);  // audio thread: drop redo layers
  float* takeBuffer();     // audio thread: zeroed loop-length buffer or null
  void serviceLoop();

  SpscQueue<int32_t, 64> commands_;
  // Zeroed layer buffers, tagged with the loop length they were made for.
  // The audio thread is the only consumer: it retires any whose length no
  // longer matches (a loop cleared and re-recorded), never writes past one.
  struct Buffer {
    float* data = nullptr;
    int64_t frames = 0;
  };
  SpscQueue<Buffer, 8> ready_;     // service → audio
  SpscQueue<float*, 64> retired_;  // audio → service: buffers to free

  std::unique_ptr<float[]> base_;  // kMaxLoopFrames + kSeamFrames

  // Audio-thread state.
  float* layerBuf_[kMaxLayers] = {};
  float layerGain_[kMaxLayers] = {};  // smoothed
  bool deleting_[kMaxLayers] = {};    // fading out, then removed
  int32_t stack_ = 0;     // layers recorded (incl. undone ones)
  int32_t active_ = 0;    // audible: [0, active_)
  int64_t len_ = 0;
  int64_t pos_ = 0;       // loop playback position
  int64_t recPos_ = 0;    // base take write position
  uint32_t seamLeft_ = 0;
  float* cur_ = nullptr;  // overdub layer being recorded
  int64_t recLeft_ = 0;   // frames of the pass still to record
  uint32_t seamTail_ = 0; // seam crossfade frames still to record
  int64_t jumpFrom_ = 0;  // old playhead, fading out after a jump to 0
  uint32_t jumpLeft_ = 0; // frames of that fade still to go

  // Shared.
  std::atomic<float> gainTarget_[kMaxLayers];
  std::atomic<int32_t> state_{kIdle};
  std::atomic<int64_t> loopLen_{0};
  std::atomic<int64_t> position_{0};
  std::atomic<int32_t> activeLayers_{0};
  std::atomic<int32_t> redoLayers_{0};
  std::atomic<int32_t> latency_{0};
  std::atomic<bool> starved_{false};
  std::atomic<float> inputPeak_{0.0f};
  std::atomic<float> outputPeak_{0.0f};
  std::atomic<float> inputGainTarget_{1.0f};
  std::atomic<float> outputGainTarget_{1.0f};
  std::atomic<bool> clipped_{false};
  float inputGain_ = 1.0f;   // audio thread, smoothed
  float outputGain_ = 1.0f;  // audio thread, smoothed
  std::atomic<bool> enabled_{false};
  std::atomic<int32_t> inProcess_{0};
  std::atomic<bool> stopService_{false};
  std::thread service_;
};

}  // namespace ps

#endif  // PS_LOOPER_H
