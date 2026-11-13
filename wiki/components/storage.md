---
type: component
status: draft
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md]
tags: [persistence]
---
# Storage

## Responsibility
App-private folder per project:
- `sources/*.wav` — immutable recordings ([[d003-non-destructive-model]]; no code path may modify them)
- `project.json` — [[edit-model]] + history
- `peaks/*.bin` — [[waveform-rendering]] caches
- `renders/*.wav` — [[dsp-processor]] output; disposable cache, safe to delete

## Files in app/
_Not written yet (M1)._
