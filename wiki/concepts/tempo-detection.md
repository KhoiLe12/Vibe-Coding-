---
type: concept
status: active
updated: 2026-11-14
sources: []
tags: [m5b, tempo, dsp]
---
# Tempo detection

How *Detect* in the [[beat-grid]] sheet finds a sample's BPM and downbeat (`app/packages/pocket_audio/src/tempo_detect.cpp`, `ps_detect_tempo`; app side `app/lib/tempo/detect.dart`). It runs offline in a background isolate on the recording, played through the take's clips, so the result is on the edit timeline whatever the pitch/tempo ([[edit-model]]). At most 90 s is analysed.

1. **Onset envelopes** (1024-point Hann FFT, hop 512 = 10.7 ms; 1024 frames of silence are put in front so a hit on the very first frame counts, since samples are often cut on the downbeat). There are three envelopes, each minus its ~0.4 s local mean and keeping only rises:
   - *full band, log magnitude* (spectral flux): every kind of hit counts, quiet or loud;
   - *below ~2 kHz, log*: kicks, snares, bass and chords, but not hats;
   - *below ~140 Hz, linear*: kicks.
2. **Tempo:** autocorrelation of the full-band envelope. Each candidate (60–200 BPM, ¼ BPM steps) is scored at its period and 2×/3×/4× multiples, times a log-Gaussian preference centred on 120 BPM (1 octave wide), because perceived tempo clusters there. The best candidate is refined ±2 % by how well a comb of beats lines up with the envelope, then snapped to a whole BPM when that fits as well.
3. **Half time:** if every other beat carries much less low/mid (<2 kHz) onset energy (more than 2×), the beat is half as fast. An example is eighth-note hats between kicks and snares, which otherwise reads as double time. Hats sit above 2 kHz, so they don't count. A kick-vs-snare level difference is not enough to trigger it.
4. **Phase and downbeat:** the beat offset whose comb lands on the most onset energy, then the beat of the bar with the most kick energy. A constant correction (half a window plus a quarter hop) converts envelope frames to the hit's position.
5. **Confidence:** how far the best score stands above the mean score (0..1). Under 0.5, the sheet says "not sure: check it by ear".

**Limits:** music without a steady beat (rubato, ambient) gives low confidence or nothing. Swing and odd signatures still get the right beat but maybe not the right bar. Real recordings can still read as half or double time, which is why ½×/2× are next to *Detect*. Tested on synthetic drum patterns only (`tempo_detect_test.dart`), so real samples are the human's check.
