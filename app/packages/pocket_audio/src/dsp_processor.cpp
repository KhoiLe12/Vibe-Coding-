// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

#define _FILE_OFFSET_BITS 64

#include "dsp_processor.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

#include "player.h"  // probeWav
#include "third_party/signalsmith/stretch/signalsmith-stretch.h"
#include "wav_writer.h"

namespace ps {
namespace {

constexpr int kBlock = 4096;  // input frames per process() call

// Reads input frames [pos, pos + n) of the range, zero-padding past its end.
class RangeReader {
 public:
  RangeReader(std::FILE* f, long dataOffset, int64_t start, int64_t end)
      : f_(f), dataOffset_(dataOffset), start_(start), end_(end) {}

  void read(int64_t pos, int n, float* out) {
    const int64_t avail = std::clamp<int64_t>(end_ - start_ - pos, 0, n);
    if (avail > 0) {
      fseeko(f_, static_cast<off_t>(dataOffset_) + (start_ + pos) * 4, SEEK_SET);
      const size_t got = std::fread(out, sizeof(float), static_cast<size_t>(avail), f_);
      std::fill(out + got, out + n, 0.0f);
    } else {
      std::fill(out, out + n, 0.0f);
    }
  }

 private:
  std::FILE* f_;
  long dataOffset_;
  int64_t start_, end_;
};

}  // namespace

DspProcessor::~DspProcessor() {
  cancel();
  joinWorker();
}

void DspProcessor::joinWorker() {
  if (worker_.joinable()) worker_.join();
}

int32_t DspProcessor::start(const RenderJob& job) {
  std::lock_guard<std::mutex> lock(mutex_);
  cancel_.store(true);
  joinWorker();
  cancel_.store(false);
  progress_.store(0.0);
  state_.store(kRenderRunning);
  const int32_t id = jobId_.fetch_add(1) + 1;
  worker_ = std::thread([this, job] {
    state_.store(run(job, cancel_, &progress_));
  });
  return id;
}

void DspProcessor::cancel() { cancel_.store(true); }

RenderState DspProcessor::run(const RenderJob& job,
                              const std::atomic<bool>& cancelled,
                              std::atomic<double>* progress) {
  std::FILE* in = std::fopen(job.input.c_str(), "rb");
  if (!in) return kRenderFailed;
  uint32_t sampleRate = 0;
  long dataOffset = 0;
  uint64_t frames = 0;
  if (!probeWav(in, &sampleRate, &dataOffset, &frames) || job.tempo <= 0 ||
      job.end <= job.start) {
    std::fclose(in);
    return kRenderFailed;
  }
  const int64_t start = std::clamp<int64_t>(job.start, 0, static_cast<int64_t>(frames));
  const int64_t end = std::clamp<int64_t>(job.end, start, static_cast<int64_t>(frames));
  const int64_t inLen = end - start;
  const int64_t outLen = std::llround(static_cast<double>(inLen) / job.tempo);
  RangeReader reader(in, dataOffset, start, end);

  const std::string tmp = job.output + ".tmp";
  WavWriter out;
  if (!out.open(tmp.c_str(), sampleRate)) {
    std::fclose(in);
    return kRenderFailed;
  }

  signalsmith::stretch::SignalsmithStretch<float> st;
  // Longer analysis blocks than presetDefault(): measured on pure tones,
  // the default lands up to +12 cents sharp at -24 semitones; 240 ms blocks
  // (30 ms interval) stay within ±3 cents across ±24. Offline, so the extra
  // latency is free; the cost is slightly softer transients (A/B by ear,
  // wiki/decisions/d013-transpose-tempo-design.md).
  st.configure(1, static_cast<int>(sampleRate * 0.24),
               static_cast<int>(sampleRate * 0.03));
  st.setTransposeSemitones(static_cast<float>(job.semitones));
  if (job.formant) {
    st.setFormantFactor(1.0f, true);  // keep formants where they were
    st.setFormantBase(0);             // detect the fundamental
  }

  const int inLat = st.inputLatency();
  const int outLat = st.outputLatency();
  std::vector<float> inBuf(std::max(kBlock, inLat)), outBuf;
  float* inPtr[1] = {inBuf.data()};

  // Pre-roll: processing time starts at the first input frame, so the
  // output carries only outputLatency() frames of lead-in, dropped below.
  reader.read(0, inLat, inBuf.data());
  st.seek(inPtr, inLat, 1.0 / job.tempo);

  int64_t inPos = inLat;      // input frames consumed
  int64_t produced = 0;       // output frames generated (incl. lead-in)
  int64_t skip = outLat;      // lead-in still to drop
  const int64_t total = outLen + outLat;
  auto emit = [&](int n) {
    const float* p = outBuf.data();
    if (skip > 0) {
      const int s = static_cast<int>(std::min<int64_t>(skip, n));
      p += s;
      n -= s;
      skip -= s;
    }
    const int64_t room = outLen - out.frames();
    n = static_cast<int>(std::min<int64_t>(n, room));
    if (n > 0) out.write(p, static_cast<size_t>(n));
  };

  // Main pass, then inputLatency() frames of silence so processing reaches
  // the end of the input.
  const int64_t inTotal = inLen + inLat;
  while (inPos < inTotal) {
    if (cancelled.load()) break;
    const int n = static_cast<int>(std::min<int64_t>(kBlock, inTotal - inPos));
    reader.read(inPos, n, inBuf.data());  // zeros past the range end
    inPos += n;
    // Output due for the input processed so far, keeping the running ratio
    // exact; the last outputLatency() frames come from flush() below.
    const int64_t due = std::llround((inPos - inLat) / job.tempo);
    const int m = static_cast<int>(
        std::max<int64_t>(0, std::min(due, outLen) - produced));
    outBuf.resize(static_cast<size_t>(std::max(m, 1)));
    float* outPtr[1] = {outBuf.data()};
    st.process(inPtr, n, outPtr, m);
    produced += m;
    emit(m);
    if (progress) {
      progress->store(std::min(1.0, static_cast<double>(inPos) / inTotal));
    }
  }
  if (!cancelled.load() && produced < total) {
    const int m = static_cast<int>(total - produced);
    outBuf.resize(static_cast<size_t>(m));
    float* outPtr[1] = {outBuf.data()};
    st.flush(outPtr, m);
    produced += m;
    emit(m);
  }
  std::fclose(in);

  if (cancelled.load()) {
    out.close();
    std::remove(tmp.c_str());
    return kRenderCancelled;
  }
  // Pad if the stretcher came up short, so the length is always exact.
  std::vector<float> zeros(1024, 0.0f);
  while (out.frames() < static_cast<uint64_t>(outLen)) {
    const size_t n = std::min<uint64_t>(zeros.size(), outLen - out.frames());
    out.write(zeros.data(), n);
  }
  if (!out.close() || std::rename(tmp.c_str(), job.output.c_str()) != 0) {
    std::remove(tmp.c_str());
    return kRenderFailed;
  }
  if (progress) progress->store(1.0);
  return kRenderDone;
}

}  // namespace ps
