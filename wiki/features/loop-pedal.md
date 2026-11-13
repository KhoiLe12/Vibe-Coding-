---
type: feature
status: draft
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-scope.md, raw/ideas/2026-10-26-looper-and-name.md]
tags: [m5, looper]
---
# Loop pedal

A dedicated screen that works like a looper pedal. Milestone M5, after the M2 latency gate ([[d001-platform-and-stack]], [[d005-loop-engine]]).

## Behaviour
- **First take sets the loop:** tap to start and tap to close. Two modes (raw/ideas/2026-10-26-looper-and-name.md):
  - **Free** (default): the loop is exactly as long as you played.
  - **Tempo sync** (toggle): set BPM by number or tap tempo, and a time signature (4/4 default). Optional count-in (1 or 2 bars) and a click you can mute. Closing the loop snaps to the nearest whole bar, so slightly early or late taps still give a clean 1, 2, 4 or 8-bar loop. The click can play in headphones only.
  - Tempo-synced loops store their BPM, so in the editor chops snap to beats and [[tempo]] changes can target a new BPM.
- **Overdub:** each pass records a new layer on top while the loop keeps playing. Layers line up sample-accurately thanks to [[latency-compensation]].
- **Layer controls:** undo/redo the last layer, mute or solo any layer, set per-layer volume, clear all.
- **Feedback mode:** optionally, old layers fade a little on each pass, like tape loops.
- **Big tap targets** for one-handed use; a Bluetooth pedal or volume button can act as the footswitch (stretch goal).
- **Bounce to editor:** the loop becomes a normal project. Each layer is its own source, so you can [[chop]], [[transpose]] and [[export]] it ([[d003-non-destructive-model]]).
- **Headphone check:** warn when recording through the phone speaker, because the mic would pick up the loop.

## Acceptance criteria
- [ ] In tempo-sync mode the loop length is exactly N bars at the set BPM, to the sample
- [ ] The loop restarts with no gap or click
- [ ] An overdub of a clap lines up with the original within 1 ms after calibration
- [ ] Undo of a layer is instant
- [ ] A 20-layer loop plays without dropouts on a mid-range phone

## Links
[[audio-engine]], [[audio-latency]], [[latency-compensation]].
