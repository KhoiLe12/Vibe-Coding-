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
- [ ] A recorded layer lines up with what was heard within 1 ms after calibration
- [ ] Sliding is sample-accurate; no clicks at layer starts and ends
- [ ] Every stack change is undoable
- [ ] 8 layers play back without dropouts
- [ ] A bounce sounds the same as the stack playing

## Links
[[audio-engine]], [[edit-model]], [[storage]], [[d015-layers]].
