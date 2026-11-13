---
type: concept
status: draft
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md]
tags: [ui]
---
# Waveform rendering

Precompute min/max peaks at several zoom levels (a peak pyramid) while recording; draw from the cache, never from raw samples. Peaks are stored as `peaks/*.bin` ([[storage]]) and drawn by [[waveform-view]].
