---
type: feature
status: draft
updated: 2026-11-14
sources: []
tags: [m6, layers, multitrack]
---
# Layers

Stack several takes and play them together — a simple multitrack. Milestone **M6** (inserted 2026-11-14, [[d015-layers]]).

*Origin:* after trying the [[loop-pedal]] (M5a), the human said what they had wanted by "loop pedal" was "the ability to take multiple recordings, and layer those together". The loop pedal stays as its own tool.

**Built 2026-11-14; four of five checks verified on the iPhone** (per-layer and whole-stack editing also confirmed): ≡ (layers) icon on the home screen creates a stack; stacks are listed above the takes; takes used in a stack say "In a stack". Stack screen: seek bar, one lane per layer (waveform at its offset; drag to slide), mute/solo/remove/volume per layer, *Add take*, *Record layer* (loop pedal's iOS mode and calibration; first use calibrates), undo/redo, bounce, delete stack. Deleting a take removes its layer from every stack (the d015 open rule). Layers with pitch/tempo play their cached render, or play unchanged with a note until the take is opened once. Max 16 layers (engine track limit).

**iPhone check 1 (human, 2026-11-14):** recording works, no clicks with 5 layers. Fixed/added: *bounce failed* ("object is unsendable": the background-isolate closure captured the screen) → top-level helper + test; *waveforms jumped when dropped* (lane scale followed the stack length) → the scale only grows; **magnetic snapping** to the stack start, other layers' starts/ends, the playhead, else the 1-second grid (faint grid lines; lane turns red when snapped); **tap a layer's name** to edit its take in the normal editor (chop, transpose, tempo…), the stack picks up the changes. **Sound-start snapping** (human: recordings often start before the sound; the grid was hidden under the lane background): each layer shows a ▼ marker where its sound starts (first point reaching 20 % of its loudest, `soundStartFrame`); while sliding, the sound start (preferred) and the file start snap to the grid, the playhead, and other layers' starts, sound starts and ends. The grid is drawn over the lanes. **Layers stay where they are put** (human: the stack re-aligned its earliest layer to 0:00 after every slide, which was annoying and made leading silence impossible); a layer slid before 0:00 stops there. **Silent stack after launch** (human: opening the app straight into a stack sometimes gave no audio until leaving and re-entering): likely iOS refusing to start audio during launch with no retry. Play (stack and take screens) and returning to the app now make sure audio is running, retrying once, and show a message instead of silence; a failed start is no longer a permanent error on the take screen. *First guess was wrong:* the human then found it happens after switching to another app and back — iOS interrupts our audio and doesn't always send "interruption ended", so the engine *looked* running but was silent. `AudioControl.ensureOutput()` now checks the audio thread's callback count actually moves (~80 ms) and restarts the engine if not. **Confirmed fixed on the iPhone 2026-11-14.** A **snap toggle** (grid icon in the top bar) turns magnetic snapping off for free placement (human request).

**Whole-stack editing** (human chose "edit the whole stack" over applying an edit to each take): ⋮ → *Edit whole stack* mixes the current arrangement into one recording (`stacks/<id>.mix-<hash>.wav`; the hash covers the arrangement and every layer's edits, so a changed stack gets a fresh mix and old renders/peaks are never reused) and opens it in the normal take editor — chop, loop, transpose, tempo, undo. The stack's edits are saved under the stack id (by time on the stack) and clamped if the mix gets shorter. The take editor gained ⋮ → *Bounce to new take* (what you hear: edits + pitch/tempo), for takes and stacks alike. The stack screen itself stays the arrangement view (unedited mix).

Engine ([[audio-engine]]): the player's timeline is now a set of **tracks** (clip list + source + offset), mixed with per-track smoothed volumes; stacks fade each track in/out over 5 ms at its ends; `openStack`/`setStack`/`setTrackGain`/`bounce`. The recorder stamps the player position of the callback that writes a take's first frame; layer offset = stamp − calibrated round trip.

## Behaviour
- A **stack** is a new item in the takes list. Each **layer** is a take (with its own edits and pitch/tempo: [[chop]], [[transpose]], [[tempo]]).
- **Add take:** pick an existing take as a new layer.
- **Record layer:** record while hearing the stack; the new recording lines up automatically using the calibrated round trip ([[latency-compensation]]), and also appears in the takes list as its own take, marked as part of a stack.
- **Slide** any layer earlier or later (sample-accurate); layers start together by default.
- Per-layer **volume / mute / solo**; remove a layer (the take itself stays).
- **Undo/redo** every stack change ([[undo-history]]).
- **Bounce** mixes the stack into a new take.
- Recording on top uses iOS's default mode so the stack is heard at normal loudness ([[d014-looper-m5a]]).

## Acceptance criteria
*Proposed during planning, approved by the human 2026-11-14.*
- [x] A recorded layer lines up with what was heard within 1 ms after calibration — iPhone 2026-11-14 (human: "works great"); host: full-callback simulation with 5/30/62 ms rooms, within 1 ms
- [x] Sliding is sample-accurate; no clicks at layer starts and ends — iPhone 2026-11-14 (human: no clicks with 5 layers; lining up "feels great" with sound-start snapping, snap toggle, no re-alignment); host: offsets exact to the frame; edges spread over 5 ms
- [x] Every stack change is undoable — iPhone 2026-11-14; host: History<LayerStack> over add/slide/volume/remove
- [x] 8 layers play back without dropouts — iPhone 16 Pro Max 2026-11-14; host: 5 s of 8 layers in 7 ms
- [ ] A bounce sounds the same as the stack playing — host: bounce = playback to 1e-6; iPhone: not yet confirmed after the isolate fix

## Links
[[audio-engine]], [[edit-model]], [[storage]], [[d015-layers]].
