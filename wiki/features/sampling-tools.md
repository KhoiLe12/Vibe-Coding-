---
type: feature
status: draft
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-scope.md]
tags: [m6, sampling]
---
# Sampling tools

For turning random sounds into usable samples (raw/ideas/2026-10-26-scope.md). Milestone M6.

## Behaviour
- **Reverse** a clip.
- **Normalize** to a peak or loudness target.
- **Fade in/out handles** on every clip.
- **Auto-trim silence** at the start and end, with a threshold.
- **Varispeed** ([[varispeed]]): tape-style pitch and speed together. The classic sampler sound; renders instantly.
- **Markers / slice points** that you can export as separate files.
- **Export** as one-shot WAV, seamless loop WAV, or a folder of slices. 48 kHz / 24-bit by default, with 44.1 kHz available ([[export]]).

## Acceptance criteria
- [ ] Every tool is non-destructive and undoable ([[non-destructive-editing]], [[undo-history]])
- [ ] Exported slices open correctly in common DAWs and samplers

## Backlog (later / ideas)
Metronome in editor mode, effects (filter, reverb, bit-crush), MIDI/keyboard to play a sample chromatically, Ableton Link sync for the looper.

## Links
[[recording-diverse-material]].
