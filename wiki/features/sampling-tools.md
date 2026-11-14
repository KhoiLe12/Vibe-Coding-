---
type: feature
status: active
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-scope.md]
tags: [m7, sampling]
---
# Sampling tools

For turning random sounds into usable samples (raw/ideas/2026-10-26-scope.md). Milestone M7. Design: [[d016-sampling-tools]].

**Built 2026-11-14. iPhone check 1 (human): everything works well except fades** — selecting a region by finger was too clunky — and *Keep voice natural* didn't apply to varispeed. Both changed the same day; the needle that replaced finger selection was **still clunky (check 2)**, so fades became corner handles on the take or selection (below); **approved by the human 2026-11-14 ("this looks great")**; committed. On the take screen: a ✨ **Sample tools** button (right of the transport) opens Reverse, Remove fades, Normalize and Trim silence, which act on the selection or, without one, the whole take. Fades are handles in the waveform's top corners. **Varispeed** is a third chip next to Pitch and Tempo, with ± semitone buttons in the same sheet. ⋮ → **Export samples…** picks One-shot / Loop / Slices and a format, then opens the share sheet. Reversed clips show ⇄ in the clip strip; reversed and faded audio shows in the waveform.

## Behaviour
- **Reverse** the selection or whole take: it plays backwards; reversing again restores it.
- **Normalize** the selection or whole take: loudest point to −1 dBFS.
- **Fade in / fade out** with **handles**: a small square hangs from the top of the waveform at the start and end of the take, or of the selection when there is one. Drag the left one right to fade in, the right one left to fade out; the curve and length ("Fade in · 0.42 s") show while dragging. Drag back to the edge to remove; *Remove fades* in the tools also clears them. Each drag is one undo step. On a chopped take one fade runs across clips without adding splits; on a selection it starts at the selection's edge (splitting there).
- **Trim silence** at the start and end of the take, below a threshold (−60 / −48 / −36 dB).
- **Varispeed** ([[varispeed]]): tape-style pitch and speed together, ±24 semitones; renders in a moment like pitch/tempo, and combines with them. *Keep voice natural* keeps formants under varispeed too (slower render).
- **Slice points = split points** ([[chop]]): every clip is a slice.
- **Export** as a one-shot WAV, a seamless loop WAV (with loop points for samplers), or one file per slice. 48 kHz / 24-bit by default; 44.1 kHz / 24-bit and 44.1 kHz / 16-bit available. Out through the share sheet (AirDrop, Files, Mail…). Exports are what you hear: edits, gain, fades, reverse, pitch, tempo, varispeed.

## Differences from the plan
*Flagged for the human; see [[d016-sampling-tools]].*
- The plan said **"fade in/out handles on every clip"**. Built (after selections, then a needle per clip, both found clunky): one fade-in and one fade-out handle on the take or the selection, always shown — not on every clip.
- The plan said **"normalize to a peak or loudness target"**. Built: peak only (−1 dBFS). Loudness (LUFS) is in the backlog.
- The plan said **"a folder of slices"**. Built: the slices are shared together as separate files (the share sheet has no folders; saving to Files puts them side by side).
- The share sheet was planned for M9 ([[export]]); it arrived now, by the human's call.

## Acceptance criteria
*From the plan (raw/plan/pocket-studio-plan.md §7), with measurable checks proposed while building — to be approved by the human.*
- [ ] Every tool is non-destructive and undoable ([[non-destructive-editing]], [[undo-history]]) — host: reverse, fade, normalize, varispeed undo back to the original edit list; nothing writes a recording. iPhone: pending
- [x] Exported slices open correctly in common DAWs and samplers — host: WAV headers, lengths and sample values checked by a parser; human 2026-11-14: a slice AirDropped to a Mac opened in FL Studio
- [ ] *(proposed)* Varispeed changes pitch by exactly the set interval with the matching length — host: within 1 cent at ×0.5/×1.5/×2, exact length, no aliasing at ×4; iPhone: by ear
- [ ] *(proposed)* An exported loop plays round without a click — host: wrap no steeper than the signal itself, at 48 and 44.1 kHz
- [ ] *(proposed)* An export matches playback — host: 24-bit export equals the clips sample for sample (within 1 LSB), reversed and with gain

## Backlog (later / ideas)
Loudness (LUFS) normalize, fade curve shapes, auto-slice at transients, metronome in editor mode, effects (filter, reverb, bit-crush), MIDI/keyboard to play a sample chromatically, Ableton Link sync for the looper.

## Links
[[recording-diverse-material]], [[audio-engine]], [[dsp-processor]], [[edit-model]], [[storage]].
