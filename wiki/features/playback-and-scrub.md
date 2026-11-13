---
type: feature
status: draft
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md]
tags: [m2, transport]
---
# Playback and scrub

Milestone M2.

## Behaviour
- Play/pause.
- Drag the playhead to scrub with audible preview.
- Rewind/forward buttons (jump ±5 s, configurable); tap-and-hold to rewind continuously.
- Loop a selected region.
- Playback reflects the current edits, not the raw file ([[non-destructive-editing]]).

## Acceptance criteria
- [ ] Playhead starts within 50 ms of tap
- [ ] Scrubbing has no clicks
- [ ] Loops are seamless

## Links
Components: [[audio-engine]], [[waveform-view]]. Concepts: [[audio-latency]], [[crossfades-and-clicks]].
