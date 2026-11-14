---
type: component
status: draft
updated: 2026-11-13
sources: [raw/plan/pocket-studio-plan.md]
tags: [persistence]
---
# Storage

## Responsibility
App-private folder per project:
- `sources/*.wav` — immutable recordings ([[d003-non-destructive-model]]; no code path may modify them)
- `project.json` — [[edit-model]] + history
- `peaks/*.bin` — [[waveform-rendering]] caches
- `renders/*.wav` — [[dsp-processor]] output; disposable cache, safe to delete

## Files in app/
M1: `app/lib/takes/take_store.dart`. Every take goes in one project, `<app documents>/projects/inbox/` (projects proper arrive in M7).
- Take id = `take-YYYYMMDD-HHMMSS` (suffix `_2`, `_3` on collision); `sources/<id>.wav` per [[d007-recording-format]], `peaks/<id>.bin` (layout in [[audio-engine]]).
- Length is read from the file size, so takes cut short by a crash are listed and play in full. Missing or short peaks are rebuilt from the WAV in a background isolate.
- `edits/<id>.json` — the take's edit list ([[edit-model]]); absent = unedited. Written to a temp file and renamed (atomic). Unreadable or out-of-range lists fall back to the whole recording. The takes list shows the edited length and an "Edited" label.
- Deleting a take removes its WAV, peaks and edits; nothing ever rewrites a recording ([[d003-non-destructive-model]]).
