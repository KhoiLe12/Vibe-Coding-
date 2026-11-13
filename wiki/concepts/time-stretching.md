---
type: concept
status: draft
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md]
tags: [dsp]
---
# Time stretching

Two families:
- **WSOLA** — time-domain overlap-add of similar segments. Cheap, good for speech, struggles with polyphony.
- **Phase vocoder** — frequency-domain. Better for music, needs phase-locking to avoid phasiness.

Libraries wrap these (see [[d002-pitch-time-library]]). Used by [[tempo]] and, via resampling, by [[pitch-shifting]].

Sources to ingest: Laroche & Dolson (1999), Verhelst & Roelands (1993) — raw/plan/pocket-studio-plan.md §6.
