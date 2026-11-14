// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

#include "tempo_detect.h"

#include <algorithm>
#include <cmath>
#include <complex>

namespace ps {
namespace {

constexpr int kN = 1024;   // FFT size
constexpr int kHop = 512;  // envelope rate: 48000 / 512 = 93.75 Hz
constexpr double kRate = 48000.0;
constexpr double kEnvRate = kRate / kHop;
constexpr double kPi = 3.14159265358979323846;

// In-place radix-2 FFT (n a power of two).
void fft(std::vector<std::complex<float>>& a) {
  const size_t n = a.size();
  for (size_t i = 1, j = 0; i < n; ++i) {
    size_t bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) std::swap(a[i], a[j]);
  }
  for (size_t len = 2; len <= n; len <<= 1) {
    const double ang = -2 * kPi / static_cast<double>(len);
    const std::complex<float> wl(static_cast<float>(std::cos(ang)),
                                 static_cast<float>(std::sin(ang)));
    for (size_t i = 0; i < n; i += len) {
      std::complex<float> w(1, 0);
      for (size_t k = 0; k < len / 2; ++k) {
        const auto u = a[i + k], v = a[i + k + len / 2] * w;
        a[i + k] = u + v;
        a[i + k + len / 2] = u - v;
        w *= wl;
      }
    }
  }
}

// Linear interpolation into x at fractional index t (0 outside).
double at(const std::vector<double>& x, double t) {
  if (t < 0) return 0;
  const size_t i = static_cast<size_t>(t);
  if (i + 1 >= x.size()) return i < x.size() ? x[i] : 0;
  const double f = t - static_cast<double>(i);
  return x[i] * (1 - f) + x[i + 1] * f;
}

// Removes the local mean (~0.4 s) and keeps only rises.
std::vector<double> rectify(const std::vector<double>& env) {
  const int64_t w = 20, n = static_cast<int64_t>(env.size());
  std::vector<double> out(env.size(), 0);
  for (int64_t i = 0; i < n; ++i) {
    double sum = 0;
    int count = 0;
    for (int64_t j = std::max<int64_t>(0, i - w); j <= std::min(n - 1, i + w);
         ++j) {
      sum += env[static_cast<size_t>(j)];
      ++count;
    }
    out[static_cast<size_t>(i)] =
        std::max(0.0, env[static_cast<size_t>(i)] - sum / count);
  }
  return out;
}

// Onset envelopes: all frequencies, log-compressed (beats); below ~2 kHz,
// log-compressed (kicks, snares, bass, chords — not hats: for half time);
// below ~140 Hz, linear (kicks, for the downbeat).
void onsetEnvelopes(const float* mono, int64_t frames, std::vector<double>& all,
                    std::vector<double>& strength, std::vector<double>& low) {
  const int64_t hops = frames >= kN ? (frames - kN) / kHop + 1 : 0;
  std::vector<double> env(static_cast<size_t>(std::max<int64_t>(hops, 0)), 0);
  std::vector<double> lowEnv(env.size(), 0), linEnv(env.size(), 0);
  std::vector<float> window(kN), prev(kN / 2 + 1, 0), mag(kN / 2 + 1);
  std::vector<float> prevLin(kN / 2 + 1, 0);
  for (int i = 0; i < kN; ++i) {
    window[i] = static_cast<float>(0.5 - 0.5 * std::cos(2 * kPi * i / kN));
  }
  std::vector<std::complex<float>> buf(kN);
  for (int64_t h = 0; h < hops; ++h) {
    const float* x = mono + h * kHop;
    for (int i = 0; i < kN; ++i) buf[i] = {x[i] * window[i], 0};
    fft(buf);
    double flux = 0, lowFlux = 0, linFlux = 0;
    for (int k = 1; k <= kN / 2; ++k) {
      // Log compression: quiet and loud onsets both count.
      const float lin = std::abs(buf[k]);
      mag[k] = std::log1p(1000.0f * lin);
      const float d = mag[k] - prev[k];
      if (d > 0 && h > 0) flux += d;
      // Kicks: linear magnitude below ~190 Hz (log compression would let
      // the low end of a snare's noise count as much).
      if (d > 0 && h > 0 && k <= 43) linFlux += d;
      if (k <= 3 && h > 0) lowFlux += std::max(0.0f, lin - prevLin[k]);
      prev[k] = mag[k];
      prevLin[k] = lin;
    }
    env[static_cast<size_t>(h)] = flux;
    lowEnv[static_cast<size_t>(h)] = lowFlux;
    linEnv[static_cast<size_t>(h)] = linFlux;
  }
  all = rectify(env);
  strength = rectify(linEnv);
  low = rectify(lowEnv);
}

}  // namespace

TempoResult detectTempo(const float* mono, int64_t frames, double minBpm,
                        double maxBpm, int32_t beatsPerBar) {
  TempoResult r;
  if (!mono || frames < kN * 4 || minBpm <= 0 || maxBpm <= minBpm) return r;
  // Silence before the audio, so a hit on its very first frame (a sample
  // cut on the downbeat) still shows as an onset.
  std::vector<float> padded(static_cast<size_t>(frames + kN), 0.0f);
  std::copy(mono, mono + frames, padded.begin() + kN);
  std::vector<double> env, strength, low;
  onsetEnvelopes(padded.data(), frames + kN, env, strength, low);
  const size_t n = env.size();
  double energy = 0;
  for (double v : env) energy += v * v;
  if (energy <= 1e-12) return r;

  // Autocorrelation up to 4 × the longest period (or what the audio allows).
  const double maxLag = std::min(4.0 * 60.0 / minBpm * kEnvRate,
                                 static_cast<double>(n) * 0.75);
  const size_t lags = static_cast<size_t>(maxLag) + 2;
  std::vector<double> ac(lags, 0);
  for (size_t L = 0; L < lags && L < n; ++L) {
    double s = 0;
    for (size_t i = L; i < n; ++i) s += env[i] * env[i - L];
    ac[L] = s / static_cast<double>(n - L);  // unbiased
  }

  // Score each tempo: the period and its multiples, times a log-Gaussian
  // preference centred on 120 BPM (1 octave wide).
  double best = -1, bestBpm = 0, sumScore = 0;
  int count = 0;
  std::vector<std::pair<double, double>> scores;
  for (double bpm = minBpm; bpm <= maxBpm; bpm += 0.25) {
    const double P = 60.0 / bpm * kEnvRate;
    double s = 0, wsum = 0;
    for (int k = 1; k <= 4; ++k) {
      if (k * P >= static_cast<double>(lags - 1)) break;
      const double wk = 1.0 / k;
      // Peak near the lag (± 1 hop), so a slightly off grid still counts.
      double m = 0;
      for (double d = -1; d <= 1; d += 0.5) m = std::max(m, at(ac, k * P + d));
      s += wk * m;
      wsum += wk;
    }
    if (wsum == 0) continue;
    s /= wsum;
    const double oct = std::log2(bpm / 120.0);
    s *= std::exp(-0.5 * oct * oct);
    scores.emplace_back(bpm, s);
    sumScore += s;
    ++count;
    if (s > best) {
      best = s;
      bestBpm = bpm;
    }
  }
  if (count == 0 || best <= 0) return r;

  // Refine: the period that best lines up the envelope over the whole
  // sample (comb of beats at the best phase), searched ±2 % in fine steps.
  auto combAt = [&](double P, double* phaseOut) {
    double bestSum = -1, bestPhase = 0;
    for (double ph = 0; ph < P; ph += 0.25) {
      double s = 0;
      for (double t = ph; t < static_cast<double>(n); t += P) s += at(env, t);
      if (s > bestSum) {
        bestSum = s;
        bestPhase = ph;
      }
    }
    if (phaseOut) *phaseOut = bestPhase;
    return bestSum / (static_cast<double>(n) / P);
  };
  double refined = bestBpm, refinedScore = -1;
  for (double bpm = bestBpm * 0.98; bpm <= bestBpm * 1.02; bpm += 0.05) {
    const double s = combAt(60.0 / bpm * kEnvRate, nullptr);
    if (s > refinedScore) {
      refinedScore = s;
      refined = bpm;
    }
  }
  // Snap to a whole BPM when that is as good (most music is).
  const double whole = std::round(refined);
  if (std::fabs(whole - refined) < 0.3 &&
      combAt(60.0 / whole * kEnvRate, nullptr) >= refinedScore * 0.995) {
    refined = whole;
  }
  double P = 60.0 / refined * kEnvRate;
  double phase = 0;
  combAt(P, &phase);

  // Half time: if every other beat has much less below 2 kHz (e.g.
  // eighth-note hats between kicks and snares), the beat is half as fast.
  // Hats sit above that, so they don't count.
  if (refined / 2 >= minBpm) {
    double even = 0, odd = 0;
    int k = 0;
    for (double t = phase; t < static_cast<double>(n); t += P, ++k) {
      (k % 2 == 0 ? even : odd) += at(strength, t);
    }
    const double hi = std::max(even, odd), lo = std::min(even, odd);
    if (hi > 2.0 * lo) {
      refined /= 2;
      if (odd > even) phase += P;
      P *= 2;
    }
  }

  // Downbeat: the beat of the bar with the most kick (low) energy; the
  // full-band envelope only breaks ties. Each scaled by its mean.
  const int bpb = beatsPerBar > 0 ? beatsPerBar : 4;
  double lowMean = 1e-12, envMean = 1e-12;
  for (size_t i = 0; i < n; ++i) {
    lowMean += low[i] / static_cast<double>(n);
    envMean += env[i] / static_cast<double>(n);
  }
  int bestBeat = 0;
  double bestBar = -1;
  for (int b = 0; b < bpb; ++b) {
    double s = 0;
    for (double t = phase + b * P; t < static_cast<double>(n); t += bpb * P) {
      s += at(low, t) / lowMean + 0.1 * at(env, t) / envMean;
    }
    if (s > bestBar) {
      bestBar = s;
      bestBeat = b;
    }
  }
  // Envelope frame h compares the window starting at h·hop with the one
  // before: an onset at sample x shows first in the window that reaches
  // it, about half a window before x. Shift by that, in frames.
  double first = (phase + bestBeat * P) * kHop + kN / 2.0 + kHop / 4.0 - kN;
  const double beatFrames = 60.0 / refined * kRate;
  while (first >= beatFrames * bpb) first -= beatFrames * bpb;
  while (first < 0) first += beatFrames * bpb;

  r.bpm = refined;
  r.firstBeat = first;
  const double mean = sumScore / count;
  r.confidence = std::clamp((best - mean) / best, 0.0, 1.0);
  return r;
}

}  // namespace ps
