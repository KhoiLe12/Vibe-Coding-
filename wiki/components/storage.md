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
M1: `app/lib/takes/take_store.dart`. Every take goes in one project, `<app documents>/projects/inbox/` (projects proper arrive in M8).
- Take id = `take-YYYYMMDD-HHMMSS` (suffix `_2`, `_3` on collision); `sources/<id>.wav` per [[d007-recording-format]], `peaks/<id>.bin` (layout in [[audio-engine]]).
- Length is read from the file size, so takes cut short by a crash are listed and play in full. Missing or short peaks are rebuilt from the WAV in a background isolate.
- `edits/<id>.json` — the take's edit list ([[edit-model]]); absent = unedited. Written to a temp file and renamed (atomic). Unreadable or out-of-range lists fall back to the whole recording. The takes list shows the edited length and an "Edited" label.
- `renders/<id>__<cents>_<tempo‰>_<formant>_<start>_<end>.wav` — renders of the recording at a pitch/tempo ([[d013-transpose-tempo-design]]): disposable cache, least-recently-used trimmed to 1 GiB, reused whenever one covers the range the edits use (±0.5 s margin). Double underscore because take ids can end in `_2`.
- The edits JSON is version 2: adds `tune` (semitones, tempo, formant); version 1 files load with no transpose.
- `calibration.json` — round trip per output route for the loop pedal ([[latency-compensation]]); in the project folder until device-wide settings exist (M8).
- Deleting a take removes its WAV, peaks, edits and renders; nothing ever rewrites a recording ([[d003-non-destructive-model]]).
