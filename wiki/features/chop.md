---
type: feature
status: draft
updated: 2026-10-26
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

## Acceptance criteria
- [ ] No audible click at any cut
- [ ] Every chop undoable ([[undo-history]])
