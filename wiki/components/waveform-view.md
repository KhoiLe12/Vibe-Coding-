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
`app/lib/widgets/waveform.dart`: `WaveformPainter` (one bar per pixel column, aggregated from cached peaks; optional playhead), `LevelMeter` (dBFS −60…0, −6 dBFS headroom mark, tap-to-reset clip light). M2 (`app/lib/screens/take_screen.dart`): one-finger drag = tape scrub; tap = seek; long-press + drag = loop selection (on/off switch, clear); two fingers = pinch-zoom (≥ 0.25 s window) and pan; an overview strip shows the whole take with the visible window and selection shaded (tap/drag to move the window); the window follows the playhead during playback. The painter takes shaded `bands` (selection, window).
