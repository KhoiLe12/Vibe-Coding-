---
type: decision
status: accepted
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-platform-and-transpose.md, raw/ideas/2026-10-26-scope.md]
tags: [platform, stack]
---
# d001 — Platform and stack

*Status: accepted (2026-10-26).*

## Context
Must ship on **iOS and Android** (raw/ideas/2026-10-26-platform-and-transpose.md). [[transpose]] and [[tempo]] may render briefly, so no real-time pitch DSP is needed. The only real-time paths are record, play and scrub (and, later, the [[loop-pedal]]).

## Options considered
1. Two native apps (Swift + Kotlin) — best platform feel, but everything is built twice. Rejected.
2. **Flutter UI + shared C++ audio core** — one UI codebase and one audio/DSP codebase. **Chosen.**
3. React Native + C++ core — viable; Flutter preferred for smooth custom drawing of the waveform and gestures.
4. JUCE for everything — one C++ codebase, but its mobile UI feels less native and needs more custom work. Kept as fallback.

## Choice
- **UI:** Flutter (Dart). The waveform is drawn with `CustomPainter` ([[waveform-view]]).
- **Audio core:** C++17, shared by both apps, called from Dart via `dart:ffi` ([[audio-engine]]).
  - Device I/O: **miniaudio** (one cross-platform layer; AAudio/OpenSL on Android, Core Audio on iOS). Fallback if latency is poor: Oboe on Android and AVAudioEngine on iOS behind the same C++ interface.
  - Pitch/time: per [[d002-pitch-time-library]], offline mode only ([[dsp-processor]]).
  - Files: WAV via miniaudio/dr_wav; AAC/M4A export through each platform's encoder via a small native plugin ([[export]]).
- Threads: audio callback (real-time safe) · C++ render worker · Dart UI isolate. Messages pass through lock-free queues.

## Consequences
One codebase for both stores; C++ build setup for Android NDK and iOS is a one-time M0 cost; mic permissions and audio-session handling (interruptions, Bluetooth, background) need per-platform code in a thin plugin.

## Follow-ups
- Set up a CI build for both platforms in M0. *(Done: workflow in [[d006-native-build]]; first run green on 2026-11-13 — Android debug APK and unsigned iOS build both succeed.)*
- *Update 2026-10-26* (raw/ideas/2026-10-26-scope.md): the [[loop-pedal]] needs full-duplex audio with low, stable latency. At the end of M2, a **go/no-go gate** measures round-trip latency on one real iPhone and one mid-range Android. Target: ≤ 30 ms on wired headphones, with no drift over 10 minutes ([[audio-latency]]). If miniaudio misses the target, switch that platform to Oboe or AVAudioEngine behind the same C++ interface before starting M5.
- *Update 2026-11-14:* the gate is now measured on the built-in speaker + mic instead of wired headphones (human has no wired headphones for a USB-C iPhone); target and drift rule unchanged — [[d008-latency-gate-route]].
- *Update 2026-11-14:* **iOS half of the gate passed** — 22.1 ms median, drift 0 over 10 min, with 64-frame periods; iOS stays on miniaudio ([[d010-duplex-buffer-size]]). Android half still open.
