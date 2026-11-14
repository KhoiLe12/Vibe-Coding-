---
type: decision
status: accepted
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-looper-and-name.md]
tags: [m5, looper, realtime]
---
# d014 — Loop pedal, part one (M5a): speaker monitoring, scope and engine design

*Status: accepted (2026-11-14). Monitoring and the M5a/M5b split are the human's calls; the engine design was made while planning and may be revisited.*

## Human's calls
- **Monitor through the phone speaker for now.** The human has no wired headphones ([[d008-latency-gate-route]]); Bluetooth's 150–300 ms delay drifts and the mic can't hear it for calibration. Consequence: the mic also records the loop into each new layer ("bleed"), so the screen warns about it on the speaker route. Wired/Bluetooth stay supported in the design (calibration per route, tap-along fallback) for later.
- **Split the milestone.** **M5a:** free-length loops, overdub, calibration, undo/redo layer, mute/solo/volume, clear, bounce to editor. **M5b:** tempo sync (BPM, tap tempo, time signature, count-in, click), feedback mode, footswitch. M5a is verified on the iPhone before M5b starts.

## Engine design (per [[d005-loop-engine]])
- Everything timing-critical is in the audio callback; the app sends commands through a lock-free queue and reads state.
- **Base take:** recorded into a preallocated buffer (max **60 s** loop). On close, recording runs on 10 ms more and that tail is crossfaded into the head, so the restart never clicks.
- **Overdub** *(superseded 2026-11-14 — see the update below)*: one new layer per pass. Each input sample is written at loop position *p − L*, where *p* is the loop position of the output frame in the same callback and *L* the calibrated round trip ([[latency-compensation]]). Recording continues *L* frames after "stop" so the end of the performance isn't lost. 5 ms fades at punch-in/out.
- **Layer buffers** (loop-length, zeroed) are prepared off the audio thread and handed over lock-free; the audio thread never allocates. Max **32 layers**.
- **Undo/redo, mute, solo, volume:** per-layer gains ramped over 5 ms — instant and click-free.
- **Calibration:** the M2 chirp probe ([[audio-latency]]), **median** of several chirps (single readings occasionally misfire, [[d010-duplex-buffer-size]]), stored per audio route.
- **Bounce to editor (M5a):** mixes the audible layers (× a chosen number of passes) into a **new take**. *Per-layer sources in the editor need multi-source projects, so they move to M8* — a deviation from the plan's "each layer is its own source", flagged for the human.

## Update 2026-11-14 (iPhone feedback): loop far too quiet
The human could barely hear the loop at 50 % phone volume. Cause (confirmed with a new playback meter and a real-device test on the Mac, where the logic worked): measurement mode gives an unprocessed mic with **no auto-gain** (quiet recordings) and **lowers speaker output**. First fix (wrong): **Mic gain** and **Loop volume** sliders at +12 dB, with a soft limiter. On the iPhone the mic then **clipped** while the loop was *still* quiet below ~70 % phone volume: measurement mode also turns off the speaker's **loudness processing**, which a limited digital signal cannot make up for. Takes sounded fine because the take screen plays in the ordinary playback mode, which keeps that processing.

**Second fix: the loop pedal runs in iOS's default mode** (PlayAndRecord + `AVAudioSessionModeDefault`), which keeps normal speaker loudness. The default mode does **not** add echo cancellation or noise suppression (those come only with the voice/video-chat modes); the mic may get light processing. The Record screen keeps measurement mode, so takes stay unprocessed ([[recording-diverse-material]]). Sliders stay (now 0 dB default) with Mic/Loop meters and the limiter. Calibration is keyed by route **and mode** (`Speaker/default-mode`), since the round trip may differ — the loop pedal recalibrates once. *Awaiting the human's check.*

## Update 2026-11-14: overdubs locked to the loop
The human found per-pass layers clunky, then asked that all layers start and record together. Now: press = arm; recording starts when the write position (*p − L*) reaches the loop start, records exactly one pass, crossfades a 10 ms seam tail into its head, and adds the layer; press again = cancel. New state `kArmed` (`PS_LOOPER_ARMED`).

## Update 2026-11-14: Overdub restarts the loop
Waiting for the loop start was clunky. Now pressing Overdub restarts playback from position 0 immediately (5 ms crossfade from the old position) and records one pass; the brief `kArmed` state only covers the round trip until the performance reaches the mic. Found while testing: two leaks across looper sessions — the restart-fade bookkeeping (could read past the end of a shorter new loop) and the smoothed mic/loop gains (first ~200 ms recorded at the previous session's gain). `enable()` now resets all audio-thread state; the earlier unreproduced suite failure was probably one of these.

## Consequences
- RAM: a 60 s loop is ~11.5 MB per layer; 32 layers ≈ 370 MB worst case. Loops are usually far shorter.
- Speaker bleed doubles the loop a little with each pass; real separation needs headphones.
