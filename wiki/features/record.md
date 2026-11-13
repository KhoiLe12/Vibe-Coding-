---
type: feature
status: draft
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-scope.md]
tags: [m1, recording]
---
# Record

Capture audio from the mic with a live waveform and level meter. Milestone M1.

## Behaviour
- Big record button; live waveform ([[waveform-view]], [[waveform-rendering]]) + input level meter while recording.
- Pause/resume appends to the same take.
- Recordings are saved immediately to disk (crash-safe, streamed to file) — see [[storage]].
- Recorded at 48 kHz and processed internally as 32-bit float, so quiet noises can be boosted and loud ones don't clip on the way in.
- Input gain control and a clip indicator.
- The OS's voice processing (noise suppression, auto-gain, echo cancel) is **off by default**, because it destroys noise and instrument recordings ([[recording-diverse-material]]).
- Optional pre-roll buffer keeps the last ~2 s before you hit record, so you never miss the start of a sound.

## Acceptance criteria
- [ ] ≥ 30 min continuous recording without dropouts
- [ ] Recording survives app backgrounding
- [ ] Take appears in the editor within 300 ms of stopping

## Links
Components: [[audio-engine]], [[storage]], [[waveform-view]]. Concepts: [[audio-latency]], [[recording-diverse-material]].
