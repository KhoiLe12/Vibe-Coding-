---
type: feature
status: draft
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md]
tags: [m3, editing]
---
# Chop

Milestone M3.

## Behaviour
- Split at playhead.
- Select a region and delete, trim to it, or duplicate it.
- Drag clips to reorder.
- Snap cuts to nearest zero-crossing; automatic 5–10 ms crossfade at every join ([[crossfades-and-clicks]]).
- All operations edit clip boundaries in the [[edit-model]]; recordings are never cut ([[non-destructive-editing]]).

Design: [[d012-chop-model]] (edit in place with *Revert to original*).

**Built 2026-11-14; done on iOS.** ✂ split at playhead; selection bar with loop / delete / trim / duplicate; clip strip (tap = select clip, long-press + drag = reorder); join markers on the waveform; undo/redo in the app bar; ⋮ → Revert to original / Delete take. Engine: 7 chop tests incl. worst-phase cuts; app: 10 edit-model tests + persistence tests.

**iPhone check 2026-11-14 (human):** no clicks or pops; undo/redo correct; edits while playing are smooth; edits survive closing the take and the app. Usability changes requested and made:
- ⇤ button in the selection bar puts the playhead at the selection start.
- Clip strip: tapping a clip outside the selection **extends** it to a contiguous block (loop/delete/trim/duplicate act on the block); tapping a clip inside it selects just that clip. Non-adjacent clips must be dragged together first (a loop is one stretch of timeline).
- Duplicate always zooms out to the whole take.
- **Bug fixed:** edits, undo and redo decided whether "the whole take was in view" *after* the history changed, so undoing a trim (and duplicating) left the view zoomed in. The check now happens before the change; a whole-take view stays whole.

## Acceptance criteria
- [x] No audible click at any cut — host tests (worst-phase cuts, gain changes); iPhone 2026-11-14: human heard no clicks or pops
- [x] Every chop undoable ([[undo-history]]) — host tests; iPhone 2026-11-14: undo/redo correct for every edit
