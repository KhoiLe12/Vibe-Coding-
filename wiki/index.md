# Index

## Overview
- [[overview]] — what Pocket Studio is, current state, roadmap position

## Features
- [[record]] — capture audio from the mic, with level meter
- [[playback-and-scrub]] — play, pause, rewind, scrub, loop a region
- [[chop]] — split, trim, delete, reorder, duplicate segments
- [[transpose]] — shift pitch up/down in semitones without changing speed
- [[tempo]] — speed up/slow down without changing pitch
- [[undo-history]] — unlimited undo/redo of edits
- [[export]] — render edits to a WAV/M4A file and share
- [[loop-pedal]] — record a loop, overdub layers in sync, mute/undo layers, bounce to the editor
- [[sampling-tools]] — varispeed, reverse, normalize, fades, one-shot/loop sample export

## Concepts
- [[non-destructive-editing]] — immutable recordings + edit list
- [[pitch-shifting]] — how transposition works and its artefacts
- [[time-stretching]] — phase vocoder vs WSOLA, quality vs latency
- [[crossfades-and-clicks]] — zero-crossings, short fades at cut points
- [[audio-latency]] — buffer sizes, round-trip latency on mobile
- [[waveform-rendering]] — peak caches for fast zoom
- [[latency-compensation]] — measuring round-trip latency and aligning overdubs
- [[varispeed]] — tape-style pitch + speed change by resampling
- [[recording-diverse-material]] — voice, instruments, noise: gain staging, transients, formants

## Components
- [[audio-engine]] — native real-time playback/record graph
- [[edit-model]] — project, clips, history data structures
- [[dsp-processor]] — pitch/tempo processing wrapper
- [[waveform-view]] — drawing, zoom, selection, gestures
- [[storage]] — files, project persistence

## Decisions
- [[d001-platform-and-stack]] — accepted: Flutter UI + shared C++ audio core, iOS + Android
- [[d002-pitch-time-library]] — accepted: Signalsmith Stretch (MIT), offline mode
- [[d003-non-destructive-model]] — accepted
- [[d004-licence]] — accepted: Apache-2.0
- [[d005-loop-engine]] — accepted: loop pedal runs fully in the C++ real-time engine
- [[d006-native-build]] — accepted: `package_ffi` build hook, vendored miniaudio, Apple ObjC++ + no runtime linking

## Questions
- [[q-transpose-scope]] — global vs per-clip transpose?

## Sources
- [[src-build-plan]] — this bootstrap plan
