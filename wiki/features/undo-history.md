---
type: feature
status: draft
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md]
tags: [m3, editing]
---
# Undo history

Milestone M3 (persistence in M8).

## Behaviour
- Every edit is a command on the [[edit-model]]; unlimited undo/redo.
- History persists with the project ([[storage]]).

## Acceptance criteria
- [x] Every edit is undoable and redoable, unlimited within a session — M3, iPhone 2026-11-14 ([[d012-chop-model]]: snapshot history)
- [ ] History survives closing and reopening (M8; until then only the current edit list is saved, [[storage]])
