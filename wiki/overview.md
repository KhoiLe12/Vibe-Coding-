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
| M2 | Navigate + latency gate ([[playback-and-scrub]], [[audio-latency]]) | Seek < 50 ms; **go/no-go** ≤ 30 ms round trip on the built-in speaker + mic ([[d008-latency-gate-route]]) |
| M3 | Chop ([[chop]], [[edit-model]], [[undo-history]]) | Every edit undoable, no clicks at cuts |
| M4 | Transpose & tempo ([[transpose]], [[tempo]]) | No tempo drift; 1-min clip ≤ 2 s; UI never blocks |
| M5 | Loop pedal ([[loop-pedal]]) | All loop-pedal acceptance criteria on both platforms |
| M6 | Sampling tools ([[sampling-tools]]) | Every tool undoable; slices import cleanly into a DAW |
| M7 | Projects | Reopened project plays identically |
| M8 | Export & release ([[export]]) | Export matches playback; lint clean; builds on both stores |
| M9+ | Backlog | Driven by raw/feedback/ |

## Current state
**Milestone 1 done on iOS** (2026-11-13): record, pause/resume, live waveform + meter, background recording, playback with basic seeking — all M1 criteria verified on an iPhone 16 Pro Max ([[record]]). **Milestone 2 done on iOS** (2026-11-14): latency gate passed (22.1 ms, drift 0; [[d010-duplex-buffer-size]]); tape-style scrub ([[d009-scrub-style]]), hold-to-rewind/fast-forward, zoom, A–B loops ([[playback-and-scrub]]) verified on the iPhone. **Milestone 3 done on iOS** (2026-11-14): split / delete / trim / duplicate / reorder with crossfaded, zero-crossing-snapped joins; unlimited undo/redo; edits saved per take ([[chop]], [[d012-chop-model]]). **Milestone 4 done on iOS** (2026-11-14): whole-take transpose (±24 st, cents, formants) and tempo (75–150 %), rendered in the background with Signalsmith Stretch, undoable ([[transpose]], [[tempo]], [[d013-transpose-tempo-design]]). **Next: M5 — loop pedal** ([[loop-pedal]], [[d005-loop-engine]], [[latency-compensation]]).

- [ ] Android half of the M2 latency gate (no device)
- [ ] M4 render speed on a **mid-range** phone (≤ 2 s per minute); only the high-end iPhone 16 Pro Max measured (0.6–1 s)

**Android: built by CI, not verified on a device.** No Android phone is available (2026-11-13). Android stays a target ([[d001-platform-and-stack]] unchanged): CI keeps the APK compiling, and the open Android checks below are done whenever a phone turns up.
- [ ] Hello tone on a real Android phone (M0)
- [ ] M1 on a real Android phone: mic permission, UNPROCESSED input, foreground-service background recording

Milestone 0 (2026-10-26 → 2026-11-13):
- [x] Folders, `CLAUDE.md`, seed wiki
- [x] `LICENSE`, `NOTICE`, `THIRD_PARTY_NOTICES.md`, `CONTRIBUTING.md` ([[d004-licence]])
- [x] Flutter app + C++ core via FFI ([[d006-native-build]], [[audio-engine]]); hello tone verified on macOS host
- [x] CI builds both platforms — first run green 2026-11-13 (github.com/KhoiLe12/Vibe-Coding-, run 43402746413)
- [x] Hello tone on a real iPhone — 2026-11-13, iPhone 16 Pro Max (iOS 26.6.2), release build
- [ ] Hello tone on a real Android phone — deferred; see Android list above
- [x] Lint passes (`tools/wiki_lint.py`: 0 errors)
