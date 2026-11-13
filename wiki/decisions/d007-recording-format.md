---
type: decision
status: accepted
updated: 2026-11-13
sources: [raw/plan/pocket-studio-plan.md]
tags: [m1, recording, storage]
---
# d007 — Recording format and M1 scope

*Status: accepted (2026-11-13, human chose all three during M1 planning).*

## Context
[[record]] says "48 kHz, processed internally as 32-bit float" but not how takes are stored on disk, how many channels, or whether the pre-roll ships in M1.

## Options considered
- **Channels:** mono (~345 MB per 30 min as float) vs stereo (~690 MB). Phone mics sit close together, so stereo adds little without an external mic.
- **File format:** 32-bit float WAV vs 24-bit PCM WAV (25% smaller, but anything boosted above full scale before saving would clip).
- **Pre-roll:** build in M1 vs later. It is in [[record]] but not in M1's done-when criteria.

## Choice
- **Mono**, 48 kHz.
- **32-bit float WAV** (`WAVE_FORMAT_IEEE_FLOAT`, with a `fact` chunk). Matches the internal format, so nothing is lost between recording and editing.
- **Pre-roll deferred** until after M1 is verified (fits naturally with the [[loop-pedal]] work in M5).

## Consequences
- 30 min ≈ 345 MB; a single take tops out near 6 h (the 4 GB WAV limit), which the recorder enforces.
- Stereo for external mics can be added later as a new option; existing mono takes stay valid.
- Files in `sources/` are written once by the recorder and never modified afterwards ([[d003-non-destructive-model]], [[storage]]).
