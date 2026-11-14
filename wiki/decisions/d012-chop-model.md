---
type: decision
status: accepted
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md]
tags: [m3, editing, undo]
---
# d012 — Chop: edit in place, snapshot undo, crossfaded joins

*Status: accepted (2026-11-14). "Edit in place" is the human's call; the rest was made while planning M3 and may be revisited.*

## Context
M3 ([[chop]]) needs split / delete / trim / duplicate / reorder with no clicks, every edit undoable ([[undo-history]]), on top of [[non-destructive-editing]] ([[d003-non-destructive-model]]).

## Choices
- **Edit in place** (human): a take *is* its edit list; the takes list shows the edited version. **Revert to original** restores the whole recording (itself an undoable edit). Alternative rejected: chopping creates a separate new take.
- **Clip list:** `Clip { srcStart, srcEnd, gain }` over the take's one recording (fades and multiple sources arrive with [[sampling-tools]] / [[loop-pedal]]; the JSON leaves room for `sourceId`). The [[audio-engine]] plays the list as one **timeline**; position, seek, loop, scrub all work in timeline frames.
- **Joins:** every join is a **10 ms equal-power crossfade** (outgoing clip runs 5 ms past its end, incoming starts 5 ms early), and every cut snaps to the **nearest zero crossing within ±5 ms** of the source ([[crossfades-and-clicks]]).
- **Undo = snapshots**, not command objects: each edit produces a new immutable clip list; history is a list of (label, list). Edit lists are tiny, so this is simpler and cannot get out of sync. Unlimited within a session.
- **Persistence:** the current clip list is saved after every edit (`edits/<take>.json`, [[storage]]). The **history** is not persisted until M7, as planned.

## Consequences
- Duplicated material crossfading into itself gets an up-to-3 dB bump inside the 10 ms join (equal-power assumes uncorrelated audio); inaudible in practice, noted for [[sampling-tools]].
- Applying an edit while playing fades out, swaps the list, and fades in (~15 ms), so edits never click either.
