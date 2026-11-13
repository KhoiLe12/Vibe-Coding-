---
type: feature
status: draft
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-platform-and-transpose.md, raw/ideas/2026-10-26-scope.md]
tags: [m4, dsp]
---
# Transpose

Milestone M4.

## Behaviour
- Up/down buttons in semitones (±24, since sampling often pushes sounds far) and an optional fine-cents slider.
- A **formant preserve** toggle, on by default for voice and off for everything else; tempo stays unchanged.
- **Render-then-play** (raw/ideas/2026-10-26-platform-and-transpose.md): each tap starts a background render in the [[dsp-processor]]. A thin progress bar shows on the waveform, and playback switches to the transposed audio when it is ready.
- Rapid taps are debounced (≈300 ms) and any in-flight render is cancelled, so only the final value renders.
- Rendered results are cached by `(source, clip range, semitones, tempo)`, so stepping back to a previous value is instant.
- One high-quality mode is used everywhere, so what you hear is exactly what gets exported ([[export]]).

## Acceptance criteria
- [ ] ±24 semitones with no tempo drift
- [ ] A 1-minute clip renders in ≤ 2 s on a mid-range phone (measure in M4)
- [ ] UI never freezes during a render
- [ ] The playhead position is kept across the switch
- [ ] Formant toggle audibly keeps a voice natural at ±5 semitones

## Links
[[pitch-shifting]], [[time-stretching]], [[d002-pitch-time-library]], [[q-transpose-scope]], [[tempo]].
