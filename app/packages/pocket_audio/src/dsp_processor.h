// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Offline pitch/time renderer (wiki/components/dsp-processor.md,
// wiki/decisions/d013-transpose-tempo-design.md). Runs Signalsmith Stretch on
// a worker thread — never the audio thread — over a range of a mono float WAV
// and writes a new mono float WAV of exactly round(length / tempo) frames.
// One job at a time; starting a job cancels the previous one. Cancellable,
// reports progress. Output is written to "<path>.tmp" and renamed when
// complete, so a render file either exists whole or not at all.

#ifndef PS_DSP_PROCESSOR_H
#define PS_DSP_PROCESSOR_H

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

namespace ps {

enum RenderState : int32_t {
  kRenderIdle = 0,
  kRenderRunning = 1,
  kRenderDone = 2,
  kRenderFailed = 3,
  kRenderCancelled = 4,
};

struct RenderJob {
  std::string input;    // mono float WAV
  int64_t start = 0;    // input frames, end exclusive
  int64_t end = 0;
  std::string output;   // mono float WAV to create
  double semitones = 0; // pitch shift (fractional = cents)
  double tempo = 1;     // speed factor; output length = length / tempo
  bool formant = false; // preserve formants (voice)
  // Varispeed (M7, wiki/concepts/varispeed.md): tape-style speed factor
  // applied after pitch/tempo by resampling, so pitch moves with it
  // (2 = an octave up, twice as fast). Output length =
  // round(round(length / tempo) / speed).
  double speed = 1;

  // Whether the Signalsmith pass is needed: pitch or tempo, or keeping
  // formants under varispeed (the pass pre-shifts them by 1 / speed so the
  // resampling puts them back where they were).
  bool stretches() const {
    return semitones != 0 || tempo != 1 || (formant && speed != 1);
  }
};

class DspProcessor {
 public:
  ~DspProcessor();

  // Starts a render (cancelling any running one). Returns a job id (> 0).
  int32_t start(const RenderJob& job);
  void cancel();

  int32_t jobId() const { return jobId_.load(); }
  RenderState state() const { return static_cast<RenderState>(state_.load()); }
  double progress() const { return progress_.load(); }

  // Runs a job on the calling thread (used by the worker and by tests).
  // Returns the final state.
  RenderState run(const RenderJob& job, const std::atomic<bool>& cancelled,
                  std::atomic<double>* progress);

 private:
  void joinWorker();
  // Signalsmith pass: [start, end) of input → output (via output.tmp).
  static RenderState stretch(const RenderJob& job, const std::string& output,
                             const std::atomic<bool>& cancelled,
                             std::atomic<double>* progress, double p0,
                             double p1);
  // Varispeed pass: [start, end) of input → output, resampled by speed.
  static RenderState varispeed(const std::string& input, int64_t start,
                               int64_t end, double speed,
                               const std::string& output,
                               const std::atomic<bool>& cancelled,
                               std::atomic<double>* progress, double p0,
                               double p1);

  std::thread worker_;
  std::atomic<bool> cancel_{false};
  std::atomic<int32_t> jobId_{0};
  std::atomic<int32_t> state_{kRenderIdle};
  std::atomic<double> progress_{0.0};
  std::mutex mutex_;
};

}  // namespace ps

#endif  // PS_DSP_PROCESSOR_H
