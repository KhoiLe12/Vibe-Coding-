---
type: decision
status: accepted
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-looper-and-name.md]
tags: [m5b, tempo, looper, grid]
---
# d017 — M5b: tempo sync everywhere, count-in click then a visual beat, no footswitch

*Status: accepted (2026-11-14). The three headline calls are the human's. The rest was decided while planning M5b and may be revisited.*

## Human's calls
- **Tempo sync is a feature of everything, not only loops.** Asked whether the editor should snap to beats, the human said: "Tempo sync should be a feature in everything, not just the loops. Like it should be in recordings as well." So recordings, takes, stacks and the loop pedal all share one idea of tempo ([[beat-grid]]). This widens the plan's M5b, which only covered the loop pedal (raw/ideas/2026-10-26-looper-and-name.md: "loops should have an option to be tempo synced").
- **The click is audible only during the count-in, then a visual beat.** The human monitors through the speaker ([[d014-looper-m5a]]), so an audible click would be recorded into takes and loop layers. A *Click while recording* toggle is there for when headphones are used.
- **No footswitch for now.** It moves to the backlog.

## Choices made while planning
- **One tempo model, the grid:** BPM, time signature (beats per bar over 4 or 8; BPM counts that beat) and a downbeat position. Tap tempo works anywhere a BPM can be set. The last tempo used is the default for the next recording, loop or stack.
- **A take's grid is saved with its edits**, on the edit timeline (edit frames, like everything in [[edit-model]]). That makes setting it undoable, and it is drawn and snapped to through pitch, tempo and varispeed (beats on screen are scaled by the take's time ratio). The grid does not count as an edit (a take with only a grid is not marked "edited"), and *Revert to original* keeps it.
  - Chopping keeps the grid where it is on the timeline: delete a beat and the audio after it moves onto the grid, as in a DAW.
- **Recording with tempo:** an optional count-in (off, 1 or 2 bars) is clicked by the engine. Recording starts **exactly at the end of the count-in**, at the audio-callback frame. The grid's downbeat is placed one calibrated round trip in (the time from the click leaving the speaker until the performer's response reaches the mic). Without a calibration for the route, the engine's reported latencies are used, and the downbeat can be moved in the editor. *Consequence:* notes played before the downbeat (pickups) are not recorded.
- **Editor:** bar and beat lines, with bars stronger. A *Snap to beats* toggle makes splits, selection edges and fade handles land on beats. *Set tempo* takes BPM, tap tempo, time signature and "downbeat at playhead". With a grid, the Tempo sheet shows the BPM you hear and can target a BPM. A *Click* toggle plays a click with playback; it is safe there because nothing is being recorded.
- **Stacks** have a grid too. Layer snapping uses beats and bars instead of the 1 s grid. The click follows playback, and goes silent while a layer records unless *Click while recording* is on.
- **Loop pedal, tempo sync:**
  - Pressing Record starts the count-in. The loop's frame 0 is the downbeat as performed, latency-compensated like overdubs.
  - Closing snaps to the **nearest whole number of bars** (at least 1). Close early and recording runs on to the bar line; close late and the extra is the seam tail.
  - Playback continues in musical time: the loop picks up exactly where the performer is, with no restart gap.
  - The loop is exactly N bars to the sample. Bounce saves the BPM and signature on the new take.
- **Feedback mode (loop pedal):** Off, −1, −3 or −6 dB per pass. Every layer fades smoothly by that much on each pass, like tape loops, and new layers start at full level. Turning it off leaves levels where they are, and Clear resets them. It affects playback and bounce only, not the recorded layers.
- **Click sound:** a 30 ms decaying sine, 1.5 kHz on the bar's first beat and 1 kHz on the others, made in the audio callback (no samples).

## Consequences
- Edits JSON gains `grid`; older files load unchanged ([[storage]]). Stack JSON gains `grid`.
- The engine gains a metronome (count-in and follow-playback click), a recorder hold (start at an exact callback frame), and looper sync and feedback ([[audio-engine]]).
- Pickups before a count-in's downbeat are lost; recording during the count-in is a possible later option.
