---
type: decision
status: accepted
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-platform-and-transpose.md, raw/ideas/2026-10-26-scope.md]
tags: [dsp, licence]
---
# d002 — Pitch/time library

*Status: accepted (2026-10-26): **Signalsmith Stretch**, offline mode.*

## Candidates (verify licences at ingest time)
- Signalsmith Stretch — modern, permissive licence (MIT), pitch + time.
- Rubber Band Library — high quality, GPL or paid commercial licence.
- SoundTouch — WSOLA-based, LGPL, light and simple.
- Platform built-ins — e.g. AVAudioUnitTimePitch on iOS (zero dependencies, iOS only).

Originally: decide after ingesting each library's docs and A/B-testing on real voice + instrument recordings.

## Updates
- *2026-10-26* (raw/ideas/2026-10-26-platform-and-transpose.md): the platform is cross-platform C++ and rendering is offline, so iOS-only built-ins are out. Every remaining candidate can run at its highest-quality offline settings.
- *2026-10-26 — accepted* (raw/ideas/2026-10-26-scope.md): **Signalsmith Stretch.** The app is open source, so Rubber Band's GPL would be allowed in principle. But GPL code in an app on Apple's App Store is legally contested; VLC was pulled from the store over it in 2011. A permissive library keeps the iOS release clean ([[d004-licence]]).

## Consequences
- Rubber Band stays as a **benchmark only** in the A/B test (voice, guitar, drum loop, noise) and is never shipped.
- If Signalsmith clearly loses on some material, reopen this decision.
- [[varispeed]] needs no library; it is plain resampling.
- Wrapped by [[dsp-processor]]; see [[pitch-shifting]], [[time-stretching]].
