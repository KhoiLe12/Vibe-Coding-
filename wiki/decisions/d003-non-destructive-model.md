---
type: decision
status: accepted
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md]
tags: [architecture]
---
# d003 — Non-destructive model

*Status: accepted.*

Edits never modify recordings; see [[non-destructive-editing]].

## Consequences
- Cheap undo ([[undo-history]]), easy re-export ([[export]]), extra render work at playback.
- Loop layers follow the same rule: each layer is a source file plus an offset ([[loop-pedal]]).
- Lint: no code path modifies a file in `sources/` ([[storage]]).
