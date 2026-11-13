---
type: component
status: draft
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-platform-and-transpose.md]
tags: [cpp, dsp]
---
# DSP processor

## Responsibility
Wraps the chosen pitch/time library ([[d002-pitch-time-library]]) in **offline mode only**. Runs on a C++ worker thread, never the audio thread. Cancellable, reports progress, and writes rendered clips to a render cache (`renders/<hash>.wav`, see [[storage]]) that the [[audio-engine]] plays like any other source. Serves [[transpose]] and [[tempo]].

## Files in app/
_Not written yet (M4)._
