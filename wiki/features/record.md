---
type: feature
status: draft
updated: 2026-11-13
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-scope.md]
tags: [m1, recording]
---
# Record

Capture audio from the mic with a live waveform and level meter. Milestone M1.

## Behaviour
- Big record button; live waveform ([[waveform-view]], [[waveform-rendering]]) + input level meter while recording.
- Pause/resume appends to the same take.
- Recordings are saved immediately to disk (crash-safe, streamed to file) — see [[storage]].
- Recorded mono at 48 kHz and stored as 32-bit float WAV ([[d007-recording-format]]), so quiet noises can be boosted and loud ones don't clip on the way in.
- Input gain control and a clip indicator.
- The OS's voice processing (noise suppression, auto-gain, echo cancel) is **off by default**, because it destroys noise and instrument recordings ([[recording-diverse-material]]).
- Optional pre-roll buffer keeps the last ~2 s before you hit record, so you never miss the start of a sound. *Deferred until after M1 ([[d007-recording-format]]).*

## Acceptance criteria
- [x] ≥ 30 min continuous recording without dropouts — host: 30 min @100× bit-exact; iPhone 16 Pro Max: 30 min take recorded and played back (start/middle/end) 2026-11-13
- [x] Recording survives app backgrounding — 2026-11-13, iPhone 16 Pro Max (lock + app switch)
- [x] Take appears in the editor within 300 ms of stopping — 2026-11-13, iPhone, every try < 300 ms

## Links
Components: [[audio-engine]], [[storage]], [[waveform-view]]. Concepts: [[audio-latency]], [[recording-diverse-material]].
