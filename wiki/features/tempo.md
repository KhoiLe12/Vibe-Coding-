---
type: feature
status: draft
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-platform-and-transpose.md]
tags: [m4, dsp]
---
# Tempo

Milestone M4.

## Behaviour
- Speed **75%–150%** without changing pitch. *The plan said 50%–200% (raw/plan/pocket-studio-plan.md); narrowed 2026-11-14 by the human to the range Signalsmith stretches well ([[d013-transpose-tempo-design]]).*
- Uses the same render-then-play flow and cache as [[transpose]] ([[dsp-processor]], [[time-stretching]]).
- Tempo-synced loops from the [[loop-pedal]] store their BPM, so tempo changes can target a new BPM. *Built in M5b:* with a [[beat-grid]], the Tempo section shows "= N BPM" for what you hear and *Play at BPM…* sets the tempo for a typed BPM (within 75–150 %).

## Acceptance criteria
*Proposed during M4 planning, approved by the human 2026-11-14.*
- [x] 75–150% with pitch unchanged: a test tone stays within ±5 cents — host at 75/125/150 % (same renderer runs on the phone)
- [x] Length is exact: within 10 ms per minute of the nominal length — host (exact to the frame)
- [x] Same as [[transpose]]: UI never freezes, playhead kept — iPhone 2026-11-14. Render speed: same caveat as transpose (high-end iPhone 0.6–1 s; mid-range open).
