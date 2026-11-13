---
type: concept
status: draft
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md]
tags: [realtime, platform]
---
# Audio latency

Real-time audio must run on a dedicated thread with **no allocation, locks or I/O**. Buffer size trades latency vs dropouts. Android needs a low-latency path (AAudio); iOS uses small IO buffer durations.

The M2 **go/no-go gate** ([[d001-platform-and-stack]]): ≤ 30 ms round trip on wired headphones, no drift over 10 minutes, on one real iPhone and one mid-range Android.

See [[latency-compensation]], [[audio-engine]], [[d005-loop-engine]].
