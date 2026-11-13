---
type: concept
status: draft
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-platform-and-transpose.md]
tags: [dsp]
---
# Pitch shifting

Transpose = time-stretch by factor *r*, then resample by 1/*r* (or a direct frequency-domain method). Ratio for *n* semitones: `2^(n/12)`.

**Artefacts:** phasiness, transient smearing, "chipmunk" formants on voice at large shifts ([[recording-diverse-material]]).

Since we render offline ([[d001-platform-and-stack]], raw/ideas/2026-10-26-platform-and-transpose.md), latency is not a constraint: pick the highest-quality settings, and give the processor look-ahead over the whole clip.

See [[time-stretching]], [[transpose]], [[d002-pitch-time-library]]. Contrast with [[varispeed]], which moves pitch and speed together.
