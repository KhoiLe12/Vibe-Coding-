---
type: feature
status: active
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-looper-and-name.md]
tags: [m5b, tempo, grid]
---
# Beat grid (tempo everywhere)

Tempo as a feature of the whole app, not just the loop pedal. The human: "Tempo sync should be a feature in everything, not just the loops. Like it should be in recordings as well." Milestone M5b. Design: [[d017-tempo-everywhere]].

**Built 2026-11-14; tried on the iPhone and approved by the human ("perfect"; the human considers the app done).** The proposed criteria below are still unticked; real-sample detection accuracy was not measured.

## Behaviour
- **One grid:** BPM (30–300; ± buttons, slider, typing, or **Tap**), time signature (2/4, 3/4, 4/4, 5/4, 6/8, 7/8, 12/8), and a downbeat. The last tempo used becomes the default everywhere.
- **Record:** a *No tempo / 120 BPM · 4/4 · 1 bar count-in* chip. With tempo on, Record clicks a count-in (off, 1 or 2 bars) and starts the take exactly on the downbeat. While recording, a **beat light** shows the beat; it is silent unless *Click while recording* (for headphones) is on. The take gets the grid, with the downbeat placed one round trip in ([[latency-compensation]]). Pause is hidden with tempo, because it would shift the grid.
- **Editor:** a **BPM** chip next to Pitch/Tempo/Varispeed opens *Beat grid*: BPM, signature, *Downbeat at playhead*, *Remove tempo* (all undoable). Bar and beat lines are drawn on the waveform. ⋮ → *Snap to beats* (on by default) puts splits, selection edges and fade handles exactly on beats; ⋮ → *Click with playback*. The Tempo section shows "= N BPM" for what you hear and has *Play at BPM…* ([[tempo]]).
- **Detect tempo** (human, 2026-11-14: "feed it music samples and it grab the tempo"): *Detect* in the editor's Beat grid sheet analyses the selection, or the whole take without one. It sets the BPM and the downbeat and says how sure it is. **½× / 2×** fix a half- or double-time reading. The result is applied with *Done* (undoable), so you can check it by ear with the click first. Details: [[tempo-detection]].
- **Stacks:** ⋮ → *Set tempo…* / *Click with playback*. Lanes show beats and bars, and layers snap to beats instead of whole seconds ([[layers]]). *Edit whole stack* opens the mix with the stack's grid.
- **Loop pedal:** see [[loop-pedal]]: tempo sync with count-in, loops of exact whole bars, a beat light, and bounce keeps the tempo.

## Acceptance criteria
*Proposed while building M5b; to be approved by the human.*
- [ ] *(proposed)* A count-in starts the take on the exact frame after it — host: first recorded sample is the count-in's next frame; click only during the count-in unless *Click while recording*. iPhone: pending
- [ ] *(proposed)* Splits and selections with *Snap to beats* land exactly on beats — host: a split at the playhead lands on the nearest beat. iPhone: pending
- [ ] *(proposed)* A take's grid survives saving, editing and *Revert*, and doesn't mark a take as edited — host
- [ ] *(proposed)* Detect finds the tempo of a drum loop within 0.3 BPM and its downbeat within 12 ms — host: synthetic kick/snare/hat patterns at 75–160 BPM (incl. 96.5), starting on frame 0 or mid-file, and a chopped take; iPhone: by ear on real samples
- [ ] *(proposed)* The editor's click lines up with the drawn grid through tempo/varispeed — iPhone, by ear

## Links
[[audio-engine]], [[edit-model]], [[storage]], [[record]], [[loop-pedal]], [[layers]].
