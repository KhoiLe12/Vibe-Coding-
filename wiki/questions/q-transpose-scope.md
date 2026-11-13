---
type: question
status: open
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md]
tags: [m4, dsp]
---
# Should transpose be global or per clip?

## Question
Should [[transpose]] apply to the whole project or per clip?

## Current best answer
Per clip is more powerful (harmonize a chopped section) but needs per-clip DSP instances in the [[dsp-processor]] and a `semitones` field on each clip in the [[edit-model]]. **Proposed:** global in M4, per-clip in a later milestone (M9+ backlog).

## What would settle it
The human's call. Awaiting it; needed before M4 starts.
