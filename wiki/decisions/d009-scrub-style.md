---
type: decision
status: accepted
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md]
tags: [m2, playback]
---
# d009 — Tape-style scrubbing

*Status: accepted (2026-11-14, human's call).*

## Context
[[playback-and-scrub]] asks for "drag the playhead to scrub with audible preview" but not what it sounds like.

## Options considered
1. **Tape-style:** playback speed and pitch follow the finger, like dragging tape over a head; slow drags sound low, backwards plays reversed. **Chosen.**
2. **Snippet-style:** short repeated grains at normal pitch at the finger position (CD/video-editor feel); words stay intelligible but it sounds choppy.

## Choice
Tape-style. The playhead's velocity sets a resampling rate on the audio thread, smoothed so speed changes never click ([[crossfades-and-clicks]]); this is the same machinery as [[varispeed]].

## Consequences
- Needs random access around the playhead in both directions, so scrubbing reads from a window around the position rather than the forward-only stream used for normal play ([[audio-engine]]).
- Resampling quality matters only for preview; export and normal playback are unaffected.
