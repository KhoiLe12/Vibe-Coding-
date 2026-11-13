---
type: decision
status: accepted
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-scope.md]
tags: [realtime, looper]
---
# d005 — Loop engine

*Status: accepted.*

The looper ([[loop-pedal]]) runs entirely inside the C++ audio callback ([[audio-engine]]): loop clock, layer playback and overdub capture. Dart only sends commands (start, close loop, overdub, undo layer, mute) through a lock-free queue and receives state for display.

## Reason
Dart and the UI thread can stall for tens of ms, which would break loop timing ([[audio-latency]]).

## Consequence
The loop-pedal milestone (M5) comes after the M2 latency gate ([[d001-platform-and-stack]]).
