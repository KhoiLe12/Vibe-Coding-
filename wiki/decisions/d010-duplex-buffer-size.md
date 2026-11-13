---
type: decision
status: accepted
updated: 2026-11-14
sources: []
tags: [m2, latency, realtime]
---
# d010 — 64-frame I/O buffers while the mic is open; iOS keeps miniaudio

*Status: accepted (2026-11-14). Follows from the M2 gate result in [[audio-latency]]; may be revisited by the human.*

## Context
The M2 go/no-go gate ([[d001-platform-and-stack]], [[d008-latency-gate-route]]) needs ≤ 30 ms round trip and no drift. With miniaudio's default 10 ms periods the iPhone measured 87.4 ms: miniaudio's iOS duplex path costs ≈ 7 periods + ~13 ms of hardware latency.

## Options considered
1. **Smaller periods with miniaudio.** 64 frames: 22.1 ms, drift 0 over 10 min, no audible crackling. 128 would be ≈ 31 ms (model, untested). **Chosen.**
2. **Native single-callback duplex on iOS** (AVAudioEngine / RemoteIO) behind the same C API — removes the 7-period chain, so safer 128–256-frame buffers would also pass. About a day of work. Kept as the fallback.

## Choice
- **iOS stays on miniaudio** (gate passed, 2026-11-14).
- **Mic open (Record, Latency, later the loop pedal): 64-frame periods** (≈ 1.3 ms; `AudioControl.duplexPeriodFrames`).
- **Playback only: miniaudio's default** (10 ms) — latency doesn't matter there and it saves battery.

## Consequences
- **Margin is ~8 ms**, and 64 frames means ~750 audio callbacks a second. Real-time work added later (looper mixing in M5) must stay light, or this decision gets revisited (option 2).
- Watch for dropouts: the Record screen warns if frames are lost. Re-checked 2026-11-14: a few minutes at 64 frames (incl. locked phone) lost nothing and played back cleanly.
- **Outliers:** each 10-min run had one stray reading (148–219 ms) among ~1200 correct ones. Anything that uses a measured latency ([[latency-compensation]] in M5) must take the **median of several chirps**, never a single one.
- **Android half of the gate is still open** (no device; [[overview]]).
