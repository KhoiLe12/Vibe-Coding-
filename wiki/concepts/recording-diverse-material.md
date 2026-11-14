---
type: concept
status: draft
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-scope.md]
tags: [recording]
---
# Recording diverse material

Voice, instruments and noise need different handling (raw/ideas/2026-10-26-scope.md):
- **Turn off the phone's voice processing.** iOS: measurement mode on the audio session. Android: the UNPROCESSED or VOICE_RECOGNITION input preset where available. *Exception: the [[loop-pedal]] uses iOS's default mode, because measurement mode also removes the speaker's loudness processing and the loop was inaudible ([[d014-looper-m5a]]).*
- **Leave headroom:** aim for peaks around −6 dBFS and normalize later ([[sampling-tools]]).
- **Transients** (claps, hits) are what pitch shifters smear first; Signalsmith settings and a transient test file belong in the A/B tests ([[d002-pitch-time-library]]).
- **Formants** matter only for voice; turn formant preservation off for noise and instruments ([[transpose]]).

Applies to [[record]].
