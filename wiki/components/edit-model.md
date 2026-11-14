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

## Files in app/
- `app/lib/edit/edit_list.dart` — `Clip`, `EditList`, `EditHistory`
- `app/test/edit_list_test.dart` — operations, timeline mapping, JSON, history
- `app/lib/screens/take_screen.dart` — editing UI ([[chop]])
