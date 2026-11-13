---
type: overview
status: active
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-platform-and-transpose.md, raw/ideas/2026-10-26-scope.md, raw/ideas/2026-10-26-looper-and-name.md, raw/ideas/2026-10-26-licence.md]
tags: [overview]
---
# Pocket Studio — overview

Pocket Studio is a record-and-edit-on-the-spot audio app. Core loop: **tap record → see waveform → scrub back → chop the good part → transpose it → play it back / export**, all within seconds and without leaving the screen.

- Everything is non-destructive ([[d003-non-destructive-model]], [[non-destructive-editing]]), so every edit is undoable ([[undo-history]]).
- Runs on **iOS and Android** from one codebase: Flutter UI + shared C++ audio core ([[d001-platform-and-stack]]).
- [[transpose]] and [[tempo]] changes are **rendered in the background for a moment, then played**, not processed live ([[dsp-processor]], [[d002-pitch-time-library]]).
- **Open source**, Apache-2.0 ([[d004-licence]]).
- Built to record **anything**: voice, instruments and raw noise for sampling ([[recording-diverse-material]], [[sampling-tools]]).
- A **loop pedal mode** ([[loop-pedal]], [[d005-loop-engine]]) builds layered loops live, then sends them into the editor to chop and transpose.

## Roadmap (raw/plan/pocket-studio-plan.md §7)
Each milestone ends with: build workflow → lint pass → log entry.

| # | Milestone | Done when |
|---|---|---|
| M0 | Bootstrap: wiki, legal files, Flutter + C++ core via FFI, "hello tone" | Lint passes; CI builds both platforms |
| M1 | Record & play ([[record]], [[storage]], [[waveform-view]]) | Record 30 min, play back, survives backgrounding |
| M2 | Navigate + latency gate ([[playback-and-scrub]], [[audio-latency]]) | Seek < 50 ms; **go/no-go** ≤ 30 ms round trip on wired headphones |
| M3 | Chop ([[chop]], [[edit-model]], [[undo-history]]) | Every edit undoable, no clicks at cuts |
| M4 | Transpose & tempo ([[transpose]], [[tempo]]) | No tempo drift; 1-min clip ≤ 2 s; UI never blocks |
| M5 | Loop pedal ([[loop-pedal]]) | All loop-pedal acceptance criteria on both platforms |
| M6 | Sampling tools ([[sampling-tools]]) | Every tool undoable; slices import cleanly into a DAW |
| M7 | Projects | Reopened project plays identically |
| M8 | Export & release ([[export]]) | Export matches playback; lint clean; builds on both stores |
| M9+ | Backlog | Driven by raw/feedback/ |

## Current state
All bootstrap decisions made. **Milestone 0 in progress** (2026-10-26):
- [x] Folders, `CLAUDE.md`, seed wiki
- [x] `LICENSE`, `NOTICE`, `THIRD_PARTY_NOTICES.md`, `CONTRIBUTING.md` ([[d004-licence]])
- [x] Flutter app + C++ core via FFI ([[d006-native-build]], [[audio-engine]]); hello tone verified on macOS host
- [ ] CI builds both platforms — workflow written, needs a GitHub remote to run
- [ ] Hello tone on a real iPhone and a real Android phone
- [x] Lint passes (`tools/wiki_lint.py`: 0 errors)
