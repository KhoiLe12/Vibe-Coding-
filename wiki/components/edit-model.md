---
type: component
status: draft
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md]
tags: [dart, model]
---
# Edit model

## Responsibility
`Project`, `Source`, `Clip`, command objects for undo/redo ([[undo-history]]), serialization to JSON. Implements [[non-destructive-editing]] per [[d003-non-destructive-model]].

## Design (M3)
Per [[d012-chop-model]]: `EditList` is an immutable list of `Clip(start, end, gain)` in **recording** frames; operations take **timeline** frames — `split`, `delete`, `trim`, `duplicate` (inserts the copy after the range), `move` (reorder), plus `locate`/`sourceAt`/`startOf` for mapping. `History<T>` (`EditHistory` = `History<EditList>`; stacks use `History<LayerStack>`, `app/lib/stack/stack.dart`) keeps snapshots: unlimited undo/redo in a session, no-op edits ignored, a new edit clears redo. JSON: `{"version":1,"clips":[{"start","end","gain"}]}`.

The take screen snaps every cut to a zero crossing (±5 ms, `PocketAudio.zeroCrossing`, never leaving its clip), and applies an edit by fading out if playing (15 ms), `PocketAudio.setClips`, re-seeking, saving, and fading back in. The engine side (timeline playback, 10 ms equal-power joins) is in [[audio-engine]].

## Sampling tools (M7, [[d016-sampling-tools]])
`Clip` gained `reverse` and `fades` (a fade-in ramp and a fade-out ramp in the clip's own frames, timeline order; ends may lie outside the clip, so `splitAt` keeps every frame's gain; for a reversed clip it cuts from the recording's end). `reversed()` mirrors the ramps. New operations: `reverse` (timeline range: clips in reverse order, each reversed), `setFadeIn`/`setFadeOut` (one clip, by length), `fadeRegionIn`/`fadeRegionOut` and `regionFadeIn`/`regionFadeOut` (one fade across a region — the take or a selection — split only at a selection's edge; the fade handles), `clearFades`, `scaleGain` (normalize). `Tune` gained `varispeed` (semitones) with `speed` and `timeRatio` = tempo × speed, which converts edit ↔ displayed frames (renders scale fades by it too). JSON version 3 adds `reverse`, `fades` and `tune.varispeed` (the first build's `env` loads as the same curve); versions 1–2 load unchanged. Export planning, peak scans and trim-silence ranges are in `app/lib/edit/sample_export.dart`.

## Files in app/
- `app/lib/edit/edit_list.dart` — `Clip`, `EditList`, `EditHistory`
- `app/test/edit_list_test.dart` — operations, timeline mapping, JSON, history
- `app/lib/edit/sample_export.dart` — export plans (one-shot, loop with seam, slices), background export, peak, sound range (M7)
- `app/test/sampling_tools_test.dart` — reverse, fades, gain, varispeed, JSON v3, export plans, sound range, timeline peaks (M7)
- `app/test/fade_handles_test.dart` — fade in/out by dragging the corner handles; a drag elsewhere still scrubs (widget test)
- `app/lib/screens/take_screen.dart` — editing UI ([[chop]])
