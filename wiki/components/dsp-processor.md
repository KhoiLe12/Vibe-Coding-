---
type: component
status: draft
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-platform-and-transpose.md]
tags: [cpp, dsp]
---
# DSP processor

## Responsibility
Wraps the chosen pitch/time library ([[d002-pitch-time-library]]) in **offline mode only**. Runs on a C++ worker thread, never the audio thread. Cancellable, reports progress, and writes rendered clips to a render cache (`renders/<hash>.wav`, see [[storage]]) that the [[audio-engine]] plays like any other source. Serves [[transpose]] and [[tempo]].

## M4 implementation
- One job at a time on a worker thread; starting a job cancels the previous one. State (idle/running/done/failed/cancelled) and progress are polled from Dart. Output goes to `<path>.tmp` and is renamed when complete, so a render exists whole or not at all.
- Exact length: `seek()` pre-roll of `inputLatency()` frames, `process()` with output paced to the running ratio, `inputLatency()` frames of silence, `flush()`, the `outputLatency()` lead-in dropped, then padded/truncated to exactly round(length / tempo).
- **Analysis block 240 ms, interval 30 ms** instead of `presetDefault()`: measured on pure tones, the default was up to **+12 cents sharp at −24 st** (+6.6 at −12, +5.1 at +0.5); 240 ms blocks stay within ±3 cents across ±24. Cost: slightly softer transients — to be judged by ear ([[recording-diverse-material]]).
- Formant preservation: `setFormantFactor(1, compensatePitch=true)` with automatic fundamental detection.
- Apple builds use Accelerate FFTs (`SIGNALSMITH_USE_ACCELERATE`).
- Host speed (Mac): a 1-minute mono render takes ~0.3 s.

## Files in app/
- `app/packages/pocket_audio/src/dsp_processor.h` / `dsp_processor.cpp` — renderer
- `app/packages/pocket_audio/src/third_party/signalsmith/` — Signalsmith Stretch 1.4.0 + Linear 0.6.4, headers + MIT licences, checksums in its README
- `app/lib/edit/render_cache.dart` — which render to use, file naming, size cap
- `app/packages/pocket_audio/test/dsp_test.dart` — exact length at 75/125/150 %, pitch kept under tempo (±5 cents), pitch exact at +12/−24/+7/+0.5 st, clicks stay within 10 ms, ranges, cancel, replace, playback from a render

## C API
`ps_render_start(input, start, end, output, semitones, tempo, formant)` → job id; `ps_render_cancel`, `ps_render_job`, `ps_render_state` (`PS_RENDER_*`), `ps_render_progress`. Dart: `PocketAudio.startRender()` etc.
