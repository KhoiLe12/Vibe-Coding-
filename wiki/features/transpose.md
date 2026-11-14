---
type: feature
status: draft
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-platform-and-transpose.md, raw/ideas/2026-10-26-scope.md]
tags: [m4, dsp]
---
# Transpose

Milestone M4.

## Behaviour
- Up/down buttons in semitones (±24, since sampling often pushes sounds far) and an optional fine-cents slider.
- A **formant preserve** toggle; tempo stays unchanged. *The plan said "on by default for voice, off otherwise"; the app can't tell voice apart, so it is **off by default** and remembered per take (human, 2026-11-14, [[d013-transpose-tempo-design]]).* Applies to the whole take ([[q-transpose-scope]]).
- **Render-then-play** (raw/ideas/2026-10-26-platform-and-transpose.md): each tap starts a background render in the [[dsp-processor]]. A thin progress bar shows on the waveform, and playback switches to the transposed audio when it is ready.
- Rapid taps are debounced (≈300 ms) and any in-flight render is cancelled, so only the final value renders.
- Rendered results are cached by `(source, clip range, semitones, tempo)`, so stepping back to a previous value is instant.
- One high-quality mode is used everywhere, so what you hear is exactly what gets exported ([[export]]).

**Built 2026-11-14; done on iOS** (iPhone check by the human the same day): Pitch/Tempo chips on the take screen open a sheet — semitone −/+ (±24), cents slider (±50), *Keep voice natural* (formants), tempo slider (75–150 %), Reset. Pitch/tempo is part of the edit state (undoable; repeated taps make one undo step; saved). Renders run 300 ms after the last change; a thin bar shows progress; playback continues on the current audio and switches at the same musical position when ready; the screen shows "Rendered m:ss in x s".

## Acceptance criteria
- [x] ±24 semitones with no tempo drift — iPhone: switch-over lands at the same place, editing while transposed works; host: length exact, clicks within 10 ms, pitch within ±5 cents at +12/−24/+7/+0.5 st
- [ ] A 1-minute clip renders in ≤ 2 s on a mid-range phone (measure in M4) — **iPhone 16 Pro Max (high-end): 0.6–1 s**; host ~0.3 s. *Left open: no mid-range phone measured* ([[overview]]).
- [x] UI never freezes during a render — iPhone 2026-11-14
- [x] The playhead position is kept across the switch — iPhone 2026-11-14
- [x] Formant toggle audibly keeps a voice natural at ±5 semitones — iPhone 2026-11-14 (human: works up to 5 semitones). Attacks stay crisp with the 240 ms blocks ([[dsp-processor]]).

## Links
[[pitch-shifting]], [[time-stretching]], [[d002-pitch-time-library]], [[q-transpose-scope]], [[tempo]].
