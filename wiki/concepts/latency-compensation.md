---
type: concept
status: draft
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md]
tags: [realtime, looper]
---
# Latency compensation

When you overdub, you hear the loop slightly late (output latency) and your playing reaches the app slightly late (input latency). Without correction, every layer drifts later.

**Fix:** measure round-trip latency once per audio route (built-in speaker/mic, wired headphones, USB), then shift each recorded layer earlier by that amount.
- Measure automatically by playing a click and detecting it at the mic, with a manual "tap along" fallback.
- Store the result per device route.
- Bluetooth headphones add 150–300 ms and vary, so warn against them in loop mode.

Needed by [[loop-pedal]]; see [[audio-latency]].
