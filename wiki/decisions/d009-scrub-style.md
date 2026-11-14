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

## Update 2026-11-14 (human feedback on the iPhone)
First build mapped the finger's **screen position** to a frame. Zoomed out on a 30-min take one pixel is seconds of audio, so even slow drags hit the 8× limit (unintelligible), the tape lagged far behind the finger, and on release the playhead jumped to the finger. Fixes, keeping tape-style:
- Scrub is **relative**: the drag moves the tape from where it was, at **min(view frames per pixel, 480 frames = 10 ms per pixel)**, so an unhurried drag (~100 px/s) plays near real time at any zoom; zoomed in closer, the needle stays under the finger.
- **On release the playhead stays where the tape is** (what was last heard), not at the finger.
- If slow tape-style scrubbing is still too hard to follow, the fallback is snippet-style or a pitch-preserving slow scrub — a new decision for the human.

## Consequences
- Needs random access around the playhead in both directions, so scrubbing reads from a window around the position rather than the forward-only stream used for normal play ([[audio-engine]]).
- Resampling quality matters only for preview; export and normal playback are unaffected.
