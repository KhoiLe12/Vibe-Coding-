---
type: decision
status: accepted
updated: 2026-11-14
sources: []
tags: [m6, layers, roadmap]
---
# d015 — Layers (multitrack) is the next milestone

*Status: accepted (2026-11-14, human's calls).*

## Context
The plan's [[loop-pedal]] was built as M5a. The human then said the feature they had meant was **layering recordings** — a multitrack — not a looper. Nothing in the plan described that ([[layers]]).

## Choices (human)
- **Both ways in:** record a new layer while hearing the stack, and add existing takes as layers.
- **Layers slide** in time; recorded ones line up automatically.
- **Recorded layers also appear as takes** in the list (marked as part of a stack).
- **Keep the loop pedal** as a separate tool, with one overdub press = one layer (fixed 2026-11-14). Its part two (**M5b**: tempo sync, count-in, click, feedback, footswitch) comes **after Layers**.
- **Roadmap:** Layers becomes **M6**; sampling tools, projects, export and the backlog each move one later (M7, M8, M9, M10+). References across the wiki were renumbered the same day (the log and the source summary keep the original numbering).
- Acceptance criteria proposed by Claude and approved: see [[layers]].

## Consequences
- The engine needs **several timelines playing at once**, each with an offset and gain — the multi-source playback the plan's Projects milestone (now M8) also needs, so M8 builds on it.
- A stack references takes by id; deleting a take that a stack uses needs a rule (warn, or remove the layer) — decided during the build.
- *2026-11-14:* the first build re-aligned the earliest layer to 0:00 after every change; removed at the human's request — offsets are kept as placed (≥ 0), so a stack can start with silence.
