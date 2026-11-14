---
type: concept
status: draft
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md]
tags: [dsp, sampling]
---
# Varispeed

Changing playback rate by resampling, like speeding up a tape. Pitch and speed move together (+12 semitones = 2× speed). Cheap, no artefacts, the signature sound of classic samplers. Needs no library ([[d002-pitch-time-library]]).

Complements [[pitch-shifting]], which keeps speed fixed. Part of [[sampling-tools]].

## In Pocket Studio (M7, [[d016-sampling-tools]])
- Range ±24 semitones: speed = 2^(st/12), 0.25×–4×. A setting of the whole take, with pitch and tempo.
- Done offline by a **band-limited** resampler (windowed sinc, 16 zero crossings, Kaiser window). "No artefacts" needs care in one direction: speeding up moves high frequencies above the new Nyquist, so the filter cutoff drops to 1/speed of it, or they would fold back down as aliasing. Slowing down needs no extra filtering.
- With pitch/tempo also set, Signalsmith runs first and varispeed resamples its output. Total time change = tempo × speed.
