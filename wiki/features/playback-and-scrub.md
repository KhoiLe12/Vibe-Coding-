---
type: feature
status: draft
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md]
tags: [m2, transport]
---
# Playback and scrub

Milestone M2. *Pulled forward into M1 (2026-11-13, human needed it to check long takes):* tap/drag the waveform to jump (seek on release, silent while dragging) and ±5 s buttons; jumps fade out then in so they don't click. Audible scrub, hold-to-rewind and the acceptance criteria below remain M2.

## Behaviour
- Play/pause.
- Drag the playhead to scrub with audible preview — **tape-style**: speed and pitch follow the finger ([[d009-scrub-style]]).
- Rewind/forward buttons (jump ±5 s, configurable); tap-and-hold to rewind continuously.
- Loop a selected region.
- Playback reflects the current edits, not the raw file ([[non-destructive-editing]]).

**Built 2026-11-14.** Human's iPhone check: jump, rewind/fast-forward (hold), loops and zoom work. Scrub was unintelligible and jumped to the finger on release → reworked to relative, zoom-independent scrubbing that stops where the tape is ([[d009-scrub-style]]); re-checked 2026-11-14: words are clear at roughly real-time drag speed, playhead stays put on release. Features: tape scrub, tap-to-seek, hold ⏪/⏩ = 4× shuttle, A–B loop by long-press + drag, pinch zoom + overview strip ([[waveform-view]], [[d011-mapped-player]]). Seeks land on the next callback; playback uses 256-frame buffers so tap → sound is estimated at ~26–31 ms ([[d010-duplex-buffer-size]]).

## Acceptance criteria
- [x] Playhead starts within 50 ms of tap — *estimate, not measured:* 256-frame playback buffers ⇒ ~26–31 ms from iOS-reported output latency; seeks land on the next callback (host tests). Human reported no delay issues.
- [x] Scrubbing has no clicks — host tests (no jumps beyond the signal's own); iPhone 2026-11-14: human reported none.
- [x] Loops are seamless — host tests (exact period, crossfaded wrap); iPhone 2026-11-14: human confirmed looping works.

## Links
Components: [[audio-engine]], [[waveform-view]]. Concepts: [[audio-latency]], [[crossfades-and-clicks]].
