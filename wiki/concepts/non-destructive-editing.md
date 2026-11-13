---
type: concept
status: draft
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md]
tags: [editing, architecture]
---
# Non-destructive editing

Recordings are immutable files. A project is a list of clips that point into them:

    Clip { sourceId, srcStart, srcEnd, gain, fadeIn, fadeOut, semitones? }

Playback and export render the list. [[chop]] edits clip boundaries; nothing is ever cut from the file. This mirrors the raw/wiki split of the LLM Wiki pattern (raw/plan/pocket-studio-plan.md §0).

Decided in [[d003-non-destructive-model]]. Implemented by [[edit-model]]; files laid out by [[storage]].
