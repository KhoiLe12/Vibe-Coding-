---
type: decision
status: accepted
updated: 2026-11-14
sources: [raw/ideas/2026-10-26-scope.md]
tags: [m2, latency, realtime]
---
# d008 — Latency gate measured on the built-in speaker and mic

*Status: accepted (2026-11-14, human's call). Amends the measurement route of the M2 gate in [[d001-platform-and-stack]] and [[audio-latency]].*

## Context
The M2 go/no-go gate was "≤ 30 ms round trip **on wired headphones**, no drift over 10 minutes, on one real iPhone and one mid-range Android". The human's iPhone 16 Pro Max has no headphone jack, and they have no USB-C earbuds or adapter. Bluetooth adds 150–300 ms and cannot be used ([[latency-compensation]]).

## Options considered
1. **Speaker + mic, provisional:** measure now on the built-in speaker/mic; the wired check stays open until wired earbuds are available.
2. **Speaker + mic, final:** the gate itself is measured on the built-in speaker/mic. **Chosen.**
3. **Wait for wired:** build the rest of M2, leave the gate open.

## Choice
- The gate is measured **acoustically on the built-in speaker and mic**: the app plays a click, detects it at the mic, and reports the round trip. Target unchanged: **≤ 30 ms, no drift over 10 minutes**.
- The OS-reported latencies (iOS: input + output latency + I/O buffer) are shown next to the measured figure, for comparison.
- No wired-headphone check is required for the gate.
- The **Android half of the gate is unchanged and still open** (no Android phone yet, see [[overview]]); it uses the same speaker/mic method when a phone turns up.

## Consequences
- The click-and-detect measurement is the same one [[latency-compensation]] needs for the [[loop-pedal]] (M5), so it is built once and reused.
- On iPhone, the built-in route's latency is usually close to wired; the speaker route can be slightly higher, so passing it is if anything stricter for the hardware path.
- The route a user actually overdubs with (wired, USB) is still measured per route at loop time by [[latency-compensation]]; this decision only changes what the M2 gate measures.
