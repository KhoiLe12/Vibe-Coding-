---
type: component
status: draft
updated: 2026-11-13
sources: [raw/plan/pocket-studio-plan.md]
tags: [dart, ui]
---
# Waveform view

## Responsibility
Renders peaks ([[waveform-rendering]]), playhead and selection with a Flutter `CustomPainter` ([[d001-platform-and-stack]]). Gestures: tap to seek, drag to scrub, pinch to zoom, long-press to select ([[playback-and-scrub]]).

## Files in app/
`app/lib/widgets/waveform.dart`: `WaveformPainter` (one bar per pixel column, aggregated from cached peaks; optional playhead), `LevelMeter` (dBFS −60…0, −6 dBFS headroom mark, tap-to-reset clip light). M1 has no gestures yet; they arrive with [[playback-and-scrub]] in M2.
