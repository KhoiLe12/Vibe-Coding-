---
type: decision
status: accepted
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-platform-and-transpose.md]
tags: [m4, dsp, transpose, tempo]
---
# d013 — Transpose & tempo: whole take, rendered from the recording

*Status: accepted (2026-11-14). Scope, tempo range and formant default are the human's calls; the render design was made while planning M4.*

## Choices
- **Whole take** ([[q-transpose-scope]]): one setting per take — semitones (±24), cents, tempo, formant on/off.
- **Tempo range 75–150%** (human). *This narrows the plan's 50–200% ([[tempo]], raw/plan/pocket-studio-plan.md):* Signalsmith's author says stretching sounds best in 0.75–1.5×, and the human preferred only offering the range that sounds good.
- **Formant preserve off by default** (human), remembered per take. The app can't tell voice from instruments; most sampling material is not voice.
- **Settings are part of the edit state:** they live in the same snapshots as the clip list, so they are undoable ([[undo-history]]) and saved with the edits ([[storage]]).
- **Render the recording, not the timeline:** the [[dsp-processor]] runs the parts of the recording the edit list uses through Signalsmith Stretch ([[d002-pitch-time-library]]) into `renders/<hash>.wav` (hash of source + range + settings). Clips then point into the render at positions scaled by 1/tempo. Chopping after a transpose needs **no re-render**; only changing a setting does.
- Render-then-play as in [[transpose]]: ~300 ms debounce, in-flight render cancelled, results cached, original keeps playing until the render is ready, then a crossfade at the same musical position.

## Update 2026-11-14 (build)
Signalsmith's `presetDefault()` measured up to +12 cents sharp at −24 st; the renderer uses 240 ms analysis blocks instead (±3 cents). See [[dsp-processor]].

## Consequences
- The UI timeline is in rendered frames; edit operations convert to recording frames (× tempo) before acting on the [[edit-model]], then snap.
- Clip boundaries in the render are placed by the nominal ratio; Signalsmith's time mapping is near-linear, and the 10 ms join crossfades ([[d012-chop-model]]) hide sub-ms differences.
- A long take with a new setting can take a while to render (whole used range); playback of the original continues meanwhile.
- `renders/` is a disposable cache with a size cap; deleting it only costs re-rendering.
