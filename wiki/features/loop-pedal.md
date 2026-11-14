---
type: feature
status: draft
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-scope.md, raw/ideas/2026-10-26-looper-and-name.md]
tags: [m5, looper]
---
# Loop pedal

A dedicated screen that works like a looper pedal. Milestone M5, after the M2 latency gate ([[d001-platform-and-stack]], [[d005-loop-engine]]).

**Overdub restarts the loop** (human, 2026-11-14: "just have all the layers always start at the exact same time"; waiting for the loop start was clunky): pressing Overdub jumps the loop back to its start at once (5 ms crossfade, no click) and records **exactly one pass**, with the same 10 ms seam crossfade as the first take, then adds the layer; pressing again cancels. (Replaced, in order: one layer per pass; one layer per press; wait-for-loop-start with a countdown.) Calibration in the loop pedal's iOS mode: 30 ms round trip on the speaker. The human clarified their main wish was [[layers]] (M6); the loop pedal is kept; M5b follows M6 and, by the human's call on 2026-11-14, M7.

**M5b built 2026-11-14 (awaiting the human's check)** ([[d017-tempo-everywhere]]). Tempo sync: the *Free / 120 BPM · 4/4* chip sets BPM (tap tempo too), signature, count-in (off/1/2 bars) and *Click while recording*. Record clicks the count-in; the loop's frame 0 is the performed downbeat (latency-compensated); *Close loop* snaps to the nearest whole bar (close early and it records on to the bar line). Playback then carries on in musical time with no restart gap, and the loop is exactly N bars to the sample. A beat light shows the beat. **Feedback** (Off, −1, −3 or −6 dB per pass): every layer fades smoothly by that much each pass, like tape. Bounce keeps the tempo as the new take's [[beat-grid]]. Footswitch: backlog (human's call).

**Split into M5a and M5b** (human, 2026-11-14; [[d014-looper-m5a]]). M5a: free loops, overdub, calibration, layer undo/redo, mute/solo/volume, clear, bounce. M5b: tempo sync, count-in/click, feedback mode, footswitch. Monitoring through the speaker for now (loop bleeds into new layers).

**M5a done on iOS 2026-11-14** (human: smooth restart, overdubs in time, bounce works, 10 layers, undo works). Layers can also be **deleted individually** (🗑 per row, 5 ms fade, first take can only be muted; not undoable). Built: ∞ icon on the home screen. Auto-calibration per route on first open (chirps for ~4 s, median), *Calibrate latency* in the menu; one big button (Record → Close loop → Overdub ⇄ Stop overdub), play/stop, undo/redo layer, clear, per-layer volume/mute/solo, bounce (1/2/4/8 passes) to a new take; speaker-bleed and Bluetooth warnings. After the first iPhone try (loop barely audible): Mic gain and Loop volume sliders (+12 dB default), Mic/Loop meters, soft limiter ([[d014-looper-m5a]]). Code: `app/lib/screens/looper_screen.dart`, `app/lib/audio/calibration.dart`, `looper.h/.cpp` ([[audio-engine]]).

## Behaviour
- **First take sets the loop:** tap to start and tap to close. Two modes (raw/ideas/2026-10-26-looper-and-name.md):
  - **Free** (default): the loop is exactly as long as you played.
  - **Tempo sync** (toggle): set BPM by number or tap tempo, and a time signature (4/4 default). Optional count-in (1 or 2 bars) and a click you can mute. Closing the loop snaps to the nearest whole bar, so slightly early or late taps still give a clean 1, 2, 4 or 8-bar loop. The click can play in headphones only.
  - Tempo-synced loops store their BPM, so in the editor chops snap to beats and [[tempo]] changes can target a new BPM.
- **Overdub:** each pass records a new layer on top while the loop keeps playing. Layers line up sample-accurately thanks to [[latency-compensation]].
- **Layer controls:** undo/redo the last layer, mute or solo any layer, set per-layer volume, clear all.
- **Feedback mode:** optionally, old layers fade a little on each pass, like tape loops.
- **Big tap targets** for one-handed use. *Footswitch (Bluetooth pedal or volume buttons): moved to the backlog by the human, 2026-11-14 ([[d017-tempo-everywhere]]).*
- **Bounce to editor:** the loop becomes a normal project. Each layer is its own source, so you can [[chop]], [[transpose]] and [[export]] it ([[d003-non-destructive-model]]). *M5a bounces a mixdown into a new take; per-layer sources wait for multi-source projects in M8 ([[d014-looper-m5a]]).*
- **Headphone check:** warn when recording through the phone speaker, because the mic would pick up the loop.

## Acceptance criteria
- [ ] In tempo-sync mode the loop length is exactly N bars at the set BPM, to the sample *(M5b)* — host: exactly 4 bars whether closed early or late, every played downbeat on a musical beat, at 0 and 300-frame round trips; iPhone: pending
- [ ] *(proposed, M5b)* Feedback fades each layer by the set amount per pass without steps — host: −6 dB per pass, no jump above 1e-3; iPhone: pending
- [x] The loop restarts with no gap or click — iPhone 2026-11-14; host: no jump beyond the signal's own at every restart
- [x] An overdub of a clap lines up with the original within 1 ms after calibration — iPhone 2026-11-14 (human: overdubs in time; 30 ms round trip calibrated on the speaker); host: exact at 0/22/100 ms simulated round trips
- [x] Undo of a layer is instant — iPhone 2026-11-14; host: next callback, silent within 5 ms
- [ ] A 20-layer loop plays without dropouts on a mid-range phone — iPhone 16 Pro Max (high-end): 10 layers fine; mid-range open; host: 5 s of 20 layers in 16 ms

## Links
[[audio-engine]], [[audio-latency]], [[latency-compensation]].
