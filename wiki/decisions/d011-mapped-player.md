---
type: decision
status: accepted
updated: 2026-11-14
sources: []
tags: [m2, playback, realtime]
---
# d011 — Player reads takes through a memory map

*Status: accepted (2026-11-14, made during M2 build; human may revisit). Supersedes the M1 streaming player described in [[audio-engine]].*

## Context
The M1 player streamed forward only: a reader thread filled a lock-free ring from the file. [[d009-scrub-style]] (tape-style scrub) needs to read backwards and jump around the playhead; loops need a crossfade between the loop end and the loop start; seeks should land within one callback ([[playback-and-scrub]]).

## Options considered
1. **Window cache:** a loader thread keeps a few seconds around the playhead in RAM, swapped to the audio thread. Strictly real-time safe, but complex (double buffering, misses when the finger outruns it).
2. **Memory map + prefetch:** map the take read-only; the audio thread reads any frame directly; a prefetch thread `madvise(WILLNEED)`s ±2–4 s around the playhead, the scrub target and the loop start every 30 ms. **Chosen.**
3. Load the whole take into RAM: 345 MB for 30 min — no.

## Choice
Option 2. One code path serves normal play, loops (5 ms crossfade, exact period), seeks (crossfade when audible, effective next callback) and scrub/shuttle.

## Consequences
- **Not strictly real-time safe:** if a page is not resident, the audio thread waits for flash. The prefetch window makes this rare; if dropouts ever show up during scrub on a device, move to option 1 behind the same API.
- Sample data starts at byte 58, so reads are unaligned and go through `memcpy` (no undefined behaviour; cheap on ARM64).
- **32-bit Android:** a multi-GB take may not fit in the address space; open would fail cleanly. 30-min takes (~345 MB) are fine.
- Files are mapped read-only, so the player cannot modify a recording ([[d003-non-destructive-model]]).
