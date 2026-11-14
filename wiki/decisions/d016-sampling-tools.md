---
type: decision
status: accepted
updated: 2026-11-14
sources: [raw/plan/pocket-studio-plan.md, raw/ideas/2026-10-26-scope.md]
tags: [m7, sampling, export, dsp]
---
# d016 — Sampling tools (M7): clip-level tools, split points as slices, share sheet now

*Status: accepted (2026-11-14). Slices, export path and varispeed range are the human's calls; the rest was decided while planning M7 and may be revisited.*

## Human's calls
- **Slices are the split points.** Each clip between ✂ cuts is one slice; "Export slices" writes one file per clip. Rejected: a second kind of marker that doesn't cut the audio.
- **Share sheet now**, via `share_plus` (BSD-3, Flutter Community; its new dependencies are also BSD-3, see `THIRD_PARTY_NOTICES.md`). The plan had the share sheet in M9 ([[export]]), but the M7 check (slices open in a DAW) needs files to leave the phone. Rejected: exposing the app's Documents folder in the Files app, which would also expose the recordings folder.
- **Varispeed ±24 semitones** (0.25×–4×), matching the range of [[transpose]].

## Choices made while planning
- **Reverse and fades live on the clip**, like gain: `Clip { start, end, gain, reverse, fades }` ([[edit-model]]). The [[audio-engine]] plays them live (reading backwards, multiplying by the fade curve), so applying a tool is instant: no render, no new file, and undo is free ([[non-destructive-editing]], [[undo-history]]).
  - *Reverse* of a selection = its clips in reverse order, each played backwards. Twice gives the original back.
  - *Fade* = a fade-in ramp and a fade-out ramp per clip, in the clip's own frames (silent before `inA`, full from `inB`; full until `outA`, silent from `outB`), on one curve (sin² of a quarter turn: flat at both ends, so neither end clicks). Ramp ends may lie outside the clip: after a split each piece keeps its share of the same curve, so a split never changes the sound. *(Superseded first build: one envelope stretched across a selection — see the update below.)*
  - Reverse, normalize and remove-fades work on the **selection, or the whole take** without one. Like chop, they split clips at the selection's edges — so a tool on a selection also adds slice points there. Fades are set with corner handles on the take or selection (updates below).
- **Normalize = peak to −1 dBFS** (headroom for 44.1 kHz conversion and players that overshoot). It scales clip gains by measuring the audio actually played (the recording, or the pitch/tempo render). *Loudness (LUFS) normalize from the plan is deferred* to the backlog.
- **Trim silence** cuts the take's start and end below a threshold (−60/−48/−36 dB, default −48), keeping 10 ms before the sound and 50 ms after, snapped to zero crossings. Works from the waveform peaks (5 ms blocks).
- **Varispeed is part of the take's Tune** (with pitch, tempo, formant), so it is undoable and saved with the edits. It renders like pitch/tempo ([[d013-transpose-tempo-design]]), but by plain resampling (no Signalsmith): a band-limited windowed-sinc resampler (16 zero crossings, Kaiser β 8, cutoff 0.97 × Nyquist). With pitch/tempo too, Signalsmith runs first, then varispeed. A minute renders in ~0.1 s on the Mac.
- **Export** (`ps_export_wav`) plays the clips with the same code as playback, so an export matches what you hear. Formats: 48 kHz/24-bit (default), 44.1 kHz/24-bit, 44.1 kHz/16-bit (TPDF dither); 44.1 kHz uses the same resampler.
  - *One-shot* = the selection or whole take, as is.
  - *Loop* = the selection or whole take, exactly as long, with a `smpl` loop chunk so samplers loop it. If audio follows the loop, its first 10 ms is crossfaded into the head, so the wrap continues as the recording did. If nothing follows (the end of the take), both ends get 2 ms fades instead. *Rejected:* shortening the loop to make a seam — it would break bar-length loops.
  - *Slices* = one file per clip (in the selection, if any), numbered.
  - Files go to a temporary folder (cleared on the next export) and out through the share sheet.

## Consequences
- The engine's clip has two more fields (reverse, fades); the C API gained `_fx` variants of set-clips and set-stack (the old ones remain). Stacks play reversed/faded layers too ([[layers]]).
- Edits JSON goes to version 3 (`reverse`, `fades`, `tune.varispeed`; the first build's `env` still loads, as the same curve); older files load unchanged. Renders with varispeed get a `v<cents>` key part; M4 render names are unchanged ([[storage]]).
- A reversed render: the engine reads a pitch/tempo render backwards, i.e. "stretch, then reverse" — not quite "reverse, then stretch" (the stretcher's transient handling differs); inaudible in practice, noted.
- Normalize ignores fades (they only lower the level), so a faded selection may peak below −1 dB.

## Update 2026-11-14 (iPhone feedback)
- **Fades with a needle.** The human: selecting a region with a finger for a fade was "way too hard and clunky"; asked for "a needle" to drag. Now *Tools › Fade in / Fade out* acts on the clip under the playhead (the whole take if it isn't chopped): a needle appears at the fade's end with the fade curve drawn, and dragging (or tapping) anywhere on the waveform moves it; *Remove* / *Done* in the bar below. A run of moves is one undo step. This needed the per-clip ramp model above: the first build stored one envelope position per clip end, which can't hold a fade in *and* out on one clip and made every fade split clips (adding slice points). *(The needle is superseded by the next update; the ramp model stays.)*
- **No crossfade where the audio and gain run on.** With ramps, a fade can end exactly at a join; the old rule (crossfade unless the clips were an untouched split) then crossfaded the audio with itself and bumped the level. The engine now skips a join's crossfade whenever the clips are contiguous in the same direction and the gain doesn't step there (< 0.1 %).
- **"Keep voice natural" works with varispeed.** The human noticed it didn't: varispeed is plain resampling, which moves formants with the pitch. With the toggle on, the Signalsmith pass now runs (even with no pitch/tempo change) with formants pre-shifted by 1/speed, so the resampling puts them back. Host test: a vowel with a 1.2 kHz resonance at varispeed ×2 keeps its peak near 1.2 kHz with the toggle (2.4 kHz without), pitch doubled either way. Costs a Signalsmith pass, so it renders slower than varispeed alone.

## Update 2026-11-14 (iPhone check 2): fade handles
- The human: the needle was "still quite clunky"; fades should "show up at the beginning/end of either the whole take, or the selected audio snippet". Now two handles are always drawn in the waveform's top corners: the fade-in handle at the region's start, the fade-out one at its end (the squares hang inward, so both stay visible at the take's edges); dragging one sets that fade's length. The region is the selection if there is one, else the whole take. The *Fade in* / *Fade out* tool entries and the needle bar are gone.
- **One curve per region**, stored in the per-clip ramps: `EditList.fadeRegionIn/Out(a, b, frames)` gives every clip the fade crosses its share of one curve from the region's edge, so on a chopped take nothing is split. On a selection the clip is split at the selection's edge (only when a fade is set), so the audio outside it is untouched. A new length replaces the old region fade on every clip; length 0 removes it. `regionFadeIn/Out` read it back from the clip at the edge.
- Grabbing: a one-finger drag that starts within ~1.5 handle widths of a handle, in the top ~45 px, drags it; anywhere else it scrubs as before. A tap or long-press on a handle does nothing. Each drag is one undo step. Rejected: handles on every clip (the plan's wording) — cluttered on chopped takes and not what the human asked for.
