---
type: concept
status: draft
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md]
tags: [realtime, platform]
---
# Audio latency

Real-time audio must run on a dedicated thread with **no allocation, locks or I/O**. Buffer size trades latency vs dropouts. Android needs a low-latency path (AAudio); iOS uses small IO buffer durations.

The M2 **go/no-go gate** ([[d001-platform-and-stack]]): ≤ 30 ms round trip, no drift over 10 minutes, on one real iPhone and one mid-range Android. Measured acoustically on the **built-in speaker + mic** (click played and detected), with the OS-reported latency alongside ([[d008-latency-gate-route]]; originally "on wired headphones").

See [[latency-compensation]], [[audio-engine]], [[d005-loop-engine]].

## How the gate is measured (M2)
- **Probe** (`latency_probe.cpp`, [[audio-engine]]): every 500 ms the audio thread adds a 5 ms Hann-windowed chirp (1.5 → 7 kHz) to the output; raw mic input goes to a lock-free ring. An analysis thread cross-correlates each chirp against the next 400 ms of input; round trip = peak position − emission frame. Input and output share one frame counter per callback, so every buffer, converter, the DAC, the air path and the ADC are included.
- **No guessing:** a detection counts only if the correlation peak is ≥ 6× the correlation's RMS; otherwise it is a "miss". Host tests feed a simulated room with known delays (256–9600 frames): exact to the sample, and doubtful detections at very low SNR are reported as misses, never as wrong values.
- **Pass rule** (Latency test screen, 10-minute run): median ≤ 30 ms **and** |median of the last minute − median of the first minute| ≤ 1 ms. *The 1 ms drift threshold is an implementation choice (≈ 48 frames); the plan only says "no drift".*
- The screen also shows iOS's reported figure: input + output latency + 2 × I/O buffer.

## Findings
- **2026-11-14, iPhone 16 Pro Max, default buffers:** 87.5 ms round trip (4200 frames), identical on every run — **3× over the 30 ms target**. Being constant to the sample points at fixed software buffering rather than the acoustic path. Known contributors in miniaudio's Core Audio backend: it overrides the session's I/O buffer with its own period (default 10 ms), and duplex mode joins two separate audio units through an intermediary ring pre-filled with 2 capture periods. Next: compare smaller requested periods (512/256/128/64 frames) on the Latency screen, which also shows the buffers iOS grants. If the target is still missed, [[d001-platform-and-stack]] says switch iOS to a native single-callback duplex path (AVAudioEngine / RemoteIO) behind the same C API.
- **2026-11-14, same phone, buffer sizes (quick 15 s tests by the human):**

  | Requested period | Granted (out / in) | Measured median (low–high) | iOS reports (in + out + 2×buffer) |
  |---|---|---|---|
  | default (10 ms) | 512×3 / 512×3 @ 48 kHz | 87.4 ms (87.3–219.4; one outlier) | 31.7 ms (0.6 + 9.7 + 2×10.7) |
  | 64 frames | 64×3 / 64×3 @ 48 kHz | **22.1 ms** (22.1–22.1) | 13 ms |

  Δ65.3 ms for Δ448 frames (9.33 ms) ⇒ round trip ≈ **7 periods + ~12.8 ms fixed** (DAC/ADC/air, close to iOS's in + out). The 7 periods are miniaudio's chain: 3 playback + 3 capture periods + the duplex ring. Implication: with miniaudio only 64-frame periods meet ≤ 30 ms (128 would be ≈ 31 ms by the same model, untested). Pending: 10-min drift run at 64 and a crackle/dropout check; if 64 is unstable, the native single-callback path removes the 7-period chain.
- **2026-11-14, gate run (10 min, 64 frames, by the human):** median **22.1 ms**, low 22.0, high 148 (one outlier), **drift 0**, iOS reports 13 ms, no audible crackling. **iOS half of the gate: PASSED** → [[d010-duplex-buffer-size]].

