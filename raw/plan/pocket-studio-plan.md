# Pocket Studio — Build Plan (LLM Wiki edition)

> An app that records audio and lets you edit it on the spot: chop, rewind/scrub, transpose up and down, and more.
> This plan follows Karpathy's **LLM Wiki** pattern (https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f):
> three layers (raw sources → wiki → schema), three operations (ingest, query, lint), and two navigation files (`index.md`, `log.md`).

**How to use this file:** drop it into an empty repo and tell your coding agent (Claude Code, Codex, etc.):
*"Bootstrap the project from `pocket-studio-plan.md`: create the folders, write `CLAUDE.md` from §2, split §3–§5 into their own files, then start Milestone 1."*
After that, this file becomes the first entry in `raw/` and is never edited again; the wiki takes over.

---

## 0. How the pattern maps onto building an app

| LLM Wiki layer | What it is here | Who writes it |
|---|---|---|
| **Raw sources** (immutable) | This plan, specs, DSP papers, library docs, your voice-memo ideas, bug reports, test recordings | You curate; the LLM only reads |
| **The wiki** | Feature pages, concept pages (DSP), component pages, decision records, open questions, overview | The LLM writes and maintains all of it |
| **The schema** | `CLAUDE.md` (or `AGENTS.md`) — conventions and workflows | You and the LLM co-evolve it |
| *(outside the wiki)* | `app/` — the actual codebase | The LLM, guided by the wiki |

| Operation | In this project |
|---|---|
| **Ingest** | A new source (a paper on pitch shifting, a library README, a note like "I want a loop button") is read, discussed, summarized, and integrated into 5–15 wiki pages. |
| **Query** | "How should transpose interact with chopping?" → LLM reads `index.md`, drills into pages, answers with citations, and files good answers back as new pages. |
| **Lint** | Health check: contradictions between decisions and code, stale claims, orphan pages, features without acceptance criteria, concepts mentioned but missing a page. |

Nice parallel: the app itself uses the same idea. **Recordings are immutable raw sources; edits are a separate, non-destructive layer on top.**

---

## 1. Directory layout

```
pocket-studio/
├── CLAUDE.md                 # the schema (§2)
├── raw/                      # immutable — LLM reads, never edits
│   ├── plan/                 # this file lives here after bootstrap
│   ├── research/             # papers, articles (clipped to markdown)
│   ├── libraries/            # READMEs / docs of audio libraries
│   ├── ideas/                # your notes, voice-memo transcripts
│   ├── feedback/             # bug reports, test-session notes
│   └── assets/               # images, screenshots, test audio
├── wiki/                     # LLM-owned
│   ├── index.md              # content catalog (§3)
│   ├── log.md                # append-only timeline (§4)
│   ├── overview.md           # the evolving synthesis of the whole app
│   ├── features/             # one page per user-facing capability
│   ├── concepts/             # DSP + audio knowledge
│   ├── components/           # one page per code module
│   ├── decisions/            # ADR-style records (accepted / open / superseded)
│   ├── questions/            # open questions + filed query answers
│   └── sources/              # one summary page per ingested raw source
└── app/                      # the codebase
```

The whole repo is git: version history of the wiki comes for free. Open `wiki/` in Obsidian to browse links and graph view while the agent works.

---

## 2. The schema — contents of `CLAUDE.md`

```markdown
# CLAUDE.md — Pocket Studio wiki maintainer

You maintain two things: the wiki in `wiki/` and the app in `app/`.
The human curates sources, asks questions and makes product calls. You do the bookkeeping.

## Layers
- `raw/` is immutable. Read it; never modify, move or delete anything in it.
- `wiki/` is yours. Create, update, merge and cross-link pages freely.
- `app/` is code. Every non-trivial code change must be reflected in the wiki
  (component page + decision page if a choice was made).

## Page types and frontmatter
Every wiki page starts with YAML frontmatter:
    ---
    type: feature | concept | component | decision | question | source | overview
    status: draft | active | done | superseded | open      # as relevant
    updated: YYYY-MM-DD
    sources: [raw/..., ...]        # raw files this page draws on
    tags: []
    ---
- feature: user story, UX behaviour, acceptance criteria, linked components/concepts.
- concept: explanation, trade-offs, parameters, links to sources.
- component: responsibility, public interface, files in `app/`, dependencies.
- decision: context, options considered, choice, consequences, status.
- question: the question, current best answer, what would settle it.
- source: summary of one raw file, key takeaways, pages it touched.

## Conventions
- Link with [[page-name]]. Every new page gets at least one inbound link.
- Extend, don't duplicate: check index.md and search wiki/ before creating a page.
- Never silently overwrite a claim. If new info contradicts a page, add a
  `## Contradictions` section citing both sources, then resolve with the human.
- Rewrite summaries when they drift; don't just append.
- Cite raw sources inline as (raw/path.md).

## Workflows
### Ingest (one source at a time, human in the loop)
1. Read the source. 2. Tell the human the 3–5 key takeaways and ask what to emphasize.
3. Write `wiki/sources/<slug>.md`. 4. Update every affected feature/concept/component/
decision page. 5. Update `overview.md` if the big picture changed.
6. Update `index.md`. 7. Append to `log.md`.

### Query
1. Read `index.md`. 2. Open relevant pages. 3. Answer with [[links]] and raw citations.
4. If the answer is reusable (comparison, design, analysis), offer to file it in
`wiki/questions/` and do so on a yes. 5. Append to `log.md`.

### Build (after any coding session)
1. Update component pages for touched modules. 2. Record any choice as a decision page.
3. Tick acceptance criteria on feature pages. 4. Append to `log.md`.

### Lint (on request, and at the end of each milestone)
Check: contradictions between pages; decisions that the code no longer matches;
stale claims; orphan pages; concepts mentioned without a page; features without
acceptance criteria; open questions that a source now answers. Suggest sources to find.
Report findings; fix only what the human approves. Append to `log.md`.

## Log format (greppable)
    ## [YYYY-MM-DD] <ingest|query|build|lint|decision> | <title>
    - pages touched: [[a]], [[b]]
    - notes: one or two lines
`grep "^## \[" wiki/log.md | tail -5` shows recent activity.
```

---

## 3. Seed `wiki/index.md`

```markdown
# Index

## Overview
- [[overview]] — what Pocket Studio is, current state, roadmap position

## Features
- [[record]] — capture audio from the mic, with level meter
- [[playback-and-scrub]] — play, pause, rewind, scrub, loop a region
- [[chop]] — split, trim, delete, reorder, duplicate segments
- [[transpose]] — shift pitch up/down in semitones without changing speed
- [[tempo]] — speed up/slow down without changing pitch
- [[undo-history]] — unlimited undo/redo of edits
- [[export]] — render edits to a WAV/M4A file and share
- [[loop-pedal]] — record a loop, overdub layers in sync, mute/undo layers, bounce to the editor
- [[sampling-tools]] — varispeed, reverse, normalize, fades, one-shot/loop sample export

## Concepts
- [[non-destructive-editing]] — immutable recordings + edit list
- [[pitch-shifting]] — how transposition works and its artefacts
- [[time-stretching]] — phase vocoder vs WSOLA, quality vs latency
- [[crossfades-and-clicks]] — zero-crossings, short fades at cut points
- [[audio-latency]] — buffer sizes, round-trip latency on mobile
- [[waveform-rendering]] — peak caches for fast zoom
- [[latency-compensation]] — measuring round-trip latency and aligning overdubs
- [[varispeed]] — tape-style pitch + speed change by resampling
- [[recording-diverse-material]] — voice, instruments, noise: gain staging, transients, formants

## Components
- [[audio-engine]] — native real-time playback/record graph
- [[edit-model]] — project, clips, history data structures
- [[dsp-processor]] — pitch/tempo processing wrapper
- [[waveform-view]] — drawing, zoom, selection, gestures
- [[storage]] — files, project persistence

## Decisions
- [[d001-platform-and-stack]] — accepted: Flutter UI + shared C++ audio core, iOS + Android
- [[d002-pitch-time-library]] — accepted: Signalsmith Stretch (MIT), offline mode
- [[d003-non-destructive-model]] — accepted
- [[d004-licence]] — accepted: Apache-2.0
- [[d005-loop-engine]] — accepted: loop pedal runs fully in the C++ real-time engine

## Questions
- [[q-transpose-scope]] — global vs per-clip transpose?

## Sources
- [[src-build-plan]] — this bootstrap plan
```

---

## 4. Seed `wiki/log.md`

```markdown
# Log

## [2026-10-26] ingest | Pocket Studio build plan
- pages touched: [[overview]], all feature pages, all concept stubs, [[d001-platform-and-stack]],
  [[d002-pitch-time-library]], [[d003-non-destructive-model]], [[q-transpose-scope]]
- notes: wiki bootstrapped; two decisions open, awaiting human input.

## [2026-10-26] decision | Platform = iOS + Android; transpose may render
- source: raw/ideas/2026-10-26-platform-and-transpose.md ("both Android and iOS; transpose can be rendered for a moment")
- pages touched: [[d001-platform-and-stack]], [[d002-pitch-time-library]], [[transpose]], [[tempo]],
  [[dsp-processor]], [[pitch-shifting]], [[overview]], [[index]]
- notes: d001 accepted. Transpose moves from live preview to render-then-play, which removes
  real-time DSP from the audio thread and lets us use the highest-quality offline mode.

## [2026-10-26] decision | Open source, record anything, loop pedal mode
- source: raw/ideas/2026-10-26-scope.md ("open source; record anything from voices and instruments
  to random noise for sampling; I do want a loop pedal mode")
- pages touched: [[d002-pitch-time-library]], [[d004-licence]], [[d005-loop-engine]], [[loop-pedal]],
  [[sampling-tools]], [[latency-compensation]], [[varispeed]], [[recording-diverse-material]],
  [[transpose]], [[record]], [[d001-platform-and-stack]], [[overview]], [[index]]
- notes: d002 accepted. The loop pedal brings real-time back for record/overdub, so round-trip latency
  is now a hard requirement; the M2 latency check becomes a go/no-go gate for miniaudio.
  Sampling use promotes reverse/normalize/varispeed from backlog to a milestone.

## [2026-10-26] decision | Tempo-synced loops; name confirmed
- source: raw/ideas/2026-10-26-looper-and-name.md ("loops should have an option to be tempo synced";
  "Pocket Studio can stay as the name")
- pages touched: [[loop-pedal]], [[overview]], [[index]]
- notes: looper has Free (default) and Tempo-sync modes with bar snapping. Name final.
  [[d004-licence]] still awaiting the human's pick.

## [2026-10-26] decision | Licence = Apache-2.0
- source: raw/ideas/2026-10-26-licence.md ("I'll go with Apache 2.0")
- pages touched: [[d004-licence]], [[overview]], [[index]]
- notes: d004 accepted. No OPEN decisions remain; ready for Milestone 0.
```

---

## 5. Seed wiki pages (the agent splits these into files)

### `overview.md`
Pocket Studio is a record-and-edit-on-the-spot audio app. Core loop: **tap record → see waveform → scrub back → chop the good part → transpose it → play it back / export**, all within seconds and without leaving the screen. Everything is non-destructive ([[d003-non-destructive-model]]), so every edit is undoable. Runs on **iOS and Android** from one codebase ([[d001-platform-and-stack]]). Transpose and tempo changes are **rendered in the background for a moment, then played**, not processed live. It is **open source** ([[d004-licence]]) and built to record **anything**: voice, instruments and raw noise for sampling ([[recording-diverse-material]], [[sampling-tools]]). A **loop pedal mode** ([[loop-pedal]]) lets you build layered loops live, then send them into the editor to chop and transpose. Licensed Apache-2.0. Current state: all bootstrap decisions made. Next: Milestone 0.

### Features

**`record.md`** — Big record button; live waveform + input level meter while recording; pause/resume appends to the same take; recordings saved immediately to disk (crash-safe, stream to file). Recorded at 48 kHz and processed internally as 32-bit float, so quiet noises can be boosted and loud ones don't clip on the way in. Input gain control and a clip indicator. The OS's voice processing (noise suppression, auto-gain, echo cancel) is **off by default**, because it destroys noise and instrument recordings ([[recording-diverse-material]]). Optional pre-roll buffer keeps the last ~2 s before you hit record, so you never miss the start of a sound. 
*Acceptance:* ≥ 30 min continuous recording without dropouts; recording survives app backgrounding; take appears in the editor within 300 ms of stopping.

**`playback-and-scrub.md`** — Play/pause; drag the playhead to scrub with audible preview; rewind/forward buttons (jump ±5 s, configurable); tap-and-hold to rewind continuously; loop a selected region; playback reflects the current edits, not the raw file.
*Acceptance:* playhead starts within 50 ms of tap; scrubbing has no clicks; loops are seamless.

**`chop.md`** — Split at playhead; select a region and delete, trim to it, or duplicate it; drag clips to reorder; snap cuts to nearest zero-crossing; automatic 5–10 ms crossfade at every join ([[crossfades-and-clicks]]).
*Acceptance:* no audible click at any cut; every chop undoable.

**`transpose.md`** — Up/down buttons in semitones (±24, since sampling often pushes sounds far) and an optional fine-cents slider; a **formant preserve** toggle, on by default for voice and off for everything else; tempo stays unchanged. **Render-then-play:** each tap starts a background render. A thin progress bar shows on the waveform, and playback switches to the transposed audio when it is ready. Rapid taps are debounced (≈300 ms) and any in-flight render is cancelled, so only the final value renders. Rendered results are cached by `(source, clip range, semitones, tempo)`, so stepping back to a previous value is instant. One high-quality mode is used everywhere, so what you hear is exactly what gets exported.
*Acceptance:* ±24 semitones with no tempo drift; a 1-minute clip renders in ≤ 2 s on a mid-range phone (measure in M4); UI never freezes during a render; the playhead position is kept across the switch; formant toggle audibly keeps a voice natural at ±5 semitones. See [[pitch-shifting]], [[q-transpose-scope]].

**`tempo.md`** — Speed 50%–200% without changing pitch; uses the same render-then-play flow and cache as transpose ([[dsp-processor]]).

**`undo-history.md`** — Every edit is a command on the [[edit-model]]; unlimited undo/redo; history persists with the project.

**`export.md`** — Render the edit list offline (high-quality mode) to WAV or AAC/M4A; share sheet; original recordings untouched.

**`loop-pedal.md`** — A dedicated screen that works like a looper pedal.
- **First take sets the loop:** tap to start and tap to close. Two modes:
  - **Free** (default): the loop is exactly as long as you played.
  - **Tempo sync** (toggle): set BPM by number or tap tempo, and a time signature (4/4 default). Optional count-in (1 or 2 bars) and a click you can mute. Closing the loop snaps to the nearest whole bar, so slightly early or late taps still give a clean 1, 2, 4 or 8-bar loop. The click can play in headphones only.
  - Tempo-synced loops store their BPM, so in the editor chops snap to beats and [[tempo]] changes can target a new BPM.
- **Overdub:** each pass records a new layer on top while the loop keeps playing. Layers line up sample-accurately thanks to [[latency-compensation]].
- **Layer controls:** undo/redo the last layer, mute or solo any layer, set per-layer volume, clear all.
- **Feedback mode:** optionally, old layers fade a little on each pass, like tape loops.
- **Big tap targets** for one-handed use; a Bluetooth pedal or volume button can act as the footswitch (stretch goal).
- **Bounce to editor:** the loop becomes a normal project. Each layer is its own source, so you can chop, transpose and export it.
- **Headphone check:** warn when recording through the phone speaker, because the mic would pick up the loop.
*Acceptance:* in tempo-sync mode the loop length is exactly N bars at the set BPM, to the sample; the loop restarts with no gap or click; an overdub of a clap lines up with the original within 1 ms after calibration; undo of a layer is instant; a 20-layer loop plays without dropouts on a mid-range phone.

**`sampling-tools.md`** — For turning random sounds into usable samples:
- **Reverse** a clip.
- **Normalize** to a peak or loudness target.
- **Fade in/out handles** on every clip.
- **Auto-trim silence** at the start and end, with a threshold.
- **Varispeed** ([[varispeed]]): tape-style pitch and speed together. This is the classic sampler sound and renders instantly.
- **Markers / slice points** that you can export as separate files.
- **Export** as one-shot WAV, seamless loop WAV, or a folder of slices. 48 kHz / 24-bit by default, with 44.1 kHz available.
*Acceptance:* every tool is non-destructive and undoable; exported slices open correctly in common DAWs and samplers.

**Later / ideas backlog:** metronome in editor mode, effects (filter, reverb, bit-crush), MIDI/keyboard to play a sample chromatically, Ableton Link sync for the looper.

### Concepts

**`non-destructive-editing.md`** — Recordings are immutable files. A project is a list of clips that point into them: `Clip { sourceId, srcStart, srcEnd, gain, fadeIn, fadeOut, semitones? }`. Playback and export render the list. Chop = edit clip boundaries; nothing is ever cut from the file. Mirrors the raw/wiki split of the LLM Wiki pattern.

**`pitch-shifting.md`** — Transpose = time-stretch by factor *r* then resample by 1/*r* (or a direct frequency-domain method). Ratio for *n* semitones: `2^(n/12)`. Artefacts: phasiness, transient smearing, "chipmunk" formants on voice at large shifts. Since we render offline ([[d001-platform-and-stack]]), latency is not a constraint: pick the highest-quality settings, and give the processor look-ahead over the whole clip.

**`time-stretching.md`** — Two families: **WSOLA** (time-domain, overlap-add of similar segments; cheap, good for speech, struggles with polyphony) and **phase vocoder** (frequency-domain; better for music, needs phase-locking to avoid phasiness). Libraries wrap these (see [[d002-pitch-time-library]]).

**`crossfades-and-clicks.md`** — A cut at a non-zero sample produces a click. Mitigate with zero-crossing snapping plus a short equal-power crossfade.

**`audio-latency.md`** — Real-time audio must run on a dedicated thread with no allocation, locks or I/O. Buffer size trades latency vs dropouts. Android needs a low-latency path; iOS uses small IO buffer durations.

**`waveform-rendering.md`** — Precompute min/max peaks at several zoom levels (a peak pyramid) while recording; draw from the cache, never from raw samples.

**`latency-compensation.md`** — When you overdub, you hear the loop slightly late (output latency) and your playing reaches the app slightly late (input latency). Without correction, every layer drifts later. The fix is to measure round-trip latency once per audio route (built-in speaker/mic, wired headphones, USB), then shift each recorded layer earlier by that amount. Measure automatically by playing a click and detecting it at the mic, with a manual "tap along" fallback. Store the result per device route. Bluetooth headphones add 150–300 ms and vary, so warn against them in loop mode.

**`varispeed.md`** — Changing playback rate by resampling, like speeding up a tape. Pitch and speed move together (+12 semitones = 2× speed). It is cheap, has no artefacts, and is the signature sound of classic samplers. It complements [[pitch-shifting]], which keeps speed fixed.

**`recording-diverse-material.md`** — Voice, instruments and noise need different handling:
- **Turn off the phone's voice processing.** iOS: use measurement mode on the audio session. Android: use the UNPROCESSED or VOICE_RECOGNITION input preset where available.
- **Leave headroom:** aim for peaks around −6 dBFS and normalize later.
- **Transients** (claps, hits) are what pitch shifters smear first; Signalsmith settings and a transient test file belong in the A/B tests.
- **Formants** matter only for voice; turn formant preservation off for noise and instruments.

### Components (stubs, filled as code is written)
- **`audio-engine.md`** — owns the device, record tap, playback of the rendered edit list, transport (play/pause/seek/loop). Also hosts the looper ([[d005-loop-engine]]): a sample-accurate loop clock, a layer mixer, and full-duplex record-while-playing with latency offset. Real-time safe.
- **`edit-model.md`** — `Project`, `Source`, `Clip`, command objects for undo/redo, serialization to JSON.
- **`dsp-processor.md`** — wraps the chosen pitch/time library in **offline mode only**. It runs on a C++ worker thread, never the audio thread. It is cancellable and reports progress, and it writes rendered clips to a render cache (`renders/<hash>.wav`) that the engine plays like any other source.
- **`waveform-view.md`** — renders peaks, playhead, selection; gestures: tap to seek, drag to scrub, pinch to zoom, long-press to select.
- **`storage.md`** — app-private folder per project: `sources/*.wav`, `project.json`, `peaks/*.bin`, `renders/*.wav` (disposable cache, safe to delete).

### Decisions

**`d001-platform-and-stack.md`** — *status: accepted (2026-10-26).*
Context: must ship on **iOS and Android** (raw/ideas/2026-10-26-platform-and-transpose.md). Transpose and tempo may render briefly, so no real-time pitch DSP is needed. The only real-time paths are record, play and scrub.
Options considered:
1. Two native apps (Swift + Kotlin) — best platform feel, but everything is built twice. Rejected.
2. **Flutter UI + shared C++ audio core** — one UI codebase and one audio/DSP codebase. **Chosen.**
3. React Native + C++ core — viable; Flutter preferred for smooth custom drawing of the waveform and gestures.
4. JUCE for everything — one C++ codebase, but its mobile UI feels less native and needs more custom work. Kept as fallback.
Choice:
- **UI:** Flutter (Dart). The waveform is drawn with `CustomPainter`.
- **Audio core:** C++17, shared by both apps, called from Dart via `dart:ffi`.
  - Device I/O: **miniaudio** (one cross-platform layer; uses AAudio/OpenSL on Android and Core Audio on iOS). Fallback if latency is poor: Oboe on Android and AVAudioEngine on iOS behind the same C++ interface.
  - Pitch/time: per [[d002-pitch-time-library]], offline mode only.
  - Files: WAV via miniaudio/dr_wav; AAC/M4A export through each platform's encoder via a small native plugin.
- Threads: audio callback (real-time safe) · C++ render worker · Dart UI isolate. Messages pass through lock-free queues.
Consequences: one codebase for both stores; C++ build setup for Android NDK and iOS is a one-time M0 cost; mic permissions and audio-session handling (interruptions, Bluetooth, background) need per-platform code in a thin plugin.

**`d001` follow-ups:** set up a CI build for both platforms in M0. *Update 2026-10-26:* the loop pedal needs full-duplex audio with low, stable latency. At the end of M2, a **go/no-go gate** measures round-trip latency on one real iPhone and one mid-range Android. Target: ≤ 30 ms on wired headphones, with no drift over 10 minutes. If miniaudio misses the target, switch that platform to Oboe or AVAudioEngine behind the same C++ interface before starting M5.

**`d002-pitch-time-library.md`** — *status: accepted (2026-10-26), see final update below.* Candidates (verify licences at ingest time):
- Signalsmith Stretch — modern, permissive licence, pitch + time.
- Rubber Band Library — high quality, GPL or paid commercial licence.
- SoundTouch — WSOLA-based, LGPL, light and simple.
- Platform built-ins — e.g. AVAudioUnitTimePitch on iOS (zero dependencies, iOS only).
Decide after ingesting each library's docs and A/B-testing on real voice + instrument recordings.
*Update 2026-10-26:* the platform is cross-platform C++ and rendering is offline, so iOS-only built-ins are out. Every remaining candidate can run at its highest-quality offline settings.
*Update 2026-10-26 — accepted:* **Signalsmith Stretch.** The app is open source, so Rubber Band's GPL would be allowed in principle. But GPL code in an app on Apple's App Store is legally contested; VLC was pulled from the store over it in 2011. A permissive library keeps the iOS release clean. Rubber Band stays as a **benchmark only** in the A/B test (voice, guitar, drum loop, noise) and is never shipped. If Signalsmith clearly loses on some material, reopen this decision. Varispeed needs no library; it is plain resampling.

**`d003-non-destructive-model.md`** — *status: accepted.* Edits never modify recordings; see [[non-destructive-editing]]. Consequences: cheap undo, easy re-export, extra render work at playback. Loop layers follow the same rule: each layer is a source file plus an offset.

**`d004-licence.md`** — *status: accepted (2026-10-26).* The app is open source under **Apache-2.0** (raw/ideas/2026-10-26-scope.md, raw/ideas/2026-10-26-licence.md).
- Why: permissive like MIT, so it is fine on both app stores and easy for contributors. It adds an explicit patent grant from contributors, which matters in audio DSP.
- Options considered: MIT (simpler, no patent grant); GPLv3 (keeps forks open, but needs contributor agreements to stay on the App Store). Both rejected.
- Check every dependency stays permissive:
  - Flutter: BSD
  - miniaudio: public domain / MIT-0
  - Signalsmith Stretch: MIT
- Avoid GPL dependencies in anything that ships (see [[d002-pitch-time-library]]).
M0 actions:
- Add `LICENSE` (Apache-2.0 full text) and a `NOTICE` file naming the copyright holder.
- Add `THIRD_PARTY_NOTICES.md` listing Flutter, miniaudio and Signalsmith Stretch with their licences, and show it on an in-app "Licences" screen.
- Add `CONTRIBUTING.md`: contributions are accepted under Apache-2.0 (inbound = outbound, no separate agreement needed).
- Lint rule: any new dependency must be permissive (MIT, BSD, Apache-2.0, zlib, public domain); GPL/LGPL needs a decision page first.

**`d005-loop-engine.md`** — *status: accepted.* The looper runs entirely inside the C++ audio callback: loop clock, layer playback and overdub capture. Dart only sends commands (start, close loop, overdub, undo layer, mute) through a lock-free queue and receives state for display. Reason: Dart and the UI thread can stall for tens of ms, which would break loop timing. Consequence: loop-pedal milestone comes after the M2 latency gate.

### Questions

**`q-transpose-scope.md`** — Should transpose apply to the whole project or per clip? Per clip is more powerful (harmonize a chopped section) but needs per-clip DSP instances. Proposed: global in M4, per-clip in a later milestone. Awaiting human call.

---

## 6. First raw sources to collect and ingest (one at a time)

1. This plan → `raw/plan/` *(already ingested at bootstrap)*
2. Docs/README of each pitch-time candidate in [[d002-pitch-time-library]] → `raw/libraries/`
3. Platform audio docs for the chosen stack (AVAudioEngine / Oboe / JUCE) → `raw/libraries/`
4. Laroche & Dolson, *Improved phase vocoder time-scale modification of audio* (1999) → `raw/research/`
5. Verhelst & Roelands, *An overlap-add technique based on waveform similarity (WSOLA)* (1993) → `raw/research/`
6. Your own notes: what "on the spot" means to you, favourite looper pedals or apps you want to feel like → `raw/ideas/`
7. Audio-latency docs: Android's audio latency guide (AAudio/Oboe) and Apple's audio-session docs on IO buffer duration and measurement mode → `raw/libraries/`
8. A test-sound pack you record yourself (voice, guitar, claps, kitchen noise, street noise) → `raw/assets/test-audio/`. Reused for every A/B and regression test.
9. After each test session: what felt slow, clicky, or confusing → `raw/feedback/`

Tip: use a web clipper to turn articles into markdown, and keep test audio in `raw/assets/`.

---

## 7. Build roadmap

Each milestone ends with: **build workflow → lint pass → log entry**.

| # | Milestone | Delivers | Done when |
|---|---|---|---|
| M0 | Bootstrap | Folders, `CLAUDE.md`, seed wiki; `LICENSE` (Apache-2.0), `NOTICE`, `THIRD_PARTY_NOTICES.md`, `CONTRIBUTING.md`; Flutter app + C++ core building on both iOS and Android via FFI, "hello tone" playing on real devices | Lint passes; CI builds both platforms |
| M1 | Record & play | [[record]], basic playback, live waveform, storage | Record 30 min, play back, survives backgrounding |
| M2 | Navigate + latency gate | Scrub, rewind/forward, loop region, zoom; round-trip latency measurement on real devices | Seek < 50 ms, click-free scrubbing; **go/no-go:** ≤ 30 ms round trip on wired headphones (else swap backend per d001) |
| M3 | Chop | Edit model, split/trim/delete/duplicate/reorder, crossfades, undo/redo | Every edit undoable, no clicks at cuts |
| M4 | Transpose & tempo | Offline DSP processor, render-then-play with progress, cancel, debounce and render cache; ±24 semitones; formant toggle; 50–200 % speed | No tempo drift; 1-min clip ≤ 2 s; UI never blocks |
| M5 | Loop pedal | Looper engine ([[d005-loop-engine]]), latency calibration, overdub layers, layer undo/mute/solo, count-in + click, bounce to editor | All [[loop-pedal]] acceptance criteria on both platforms |
| M6 | Sampling tools | Reverse, normalize, fades, auto-trim, varispeed, slice markers | Every tool undoable; slices import cleanly into a DAW |
| M7 | Projects | Save/reopen projects, history persisted, take and loop list | Reopened project plays identically |
| M8 | Export & release | One-shot / loop / slices export, share sheet, onboarding, perf pass; public repo, store listings | Export matches playback; lint clean; builds on both stores |
| M9+ | Backlog | Per-clip transpose, effects, chromatic sample playback, footswitch, Ableton Link | Driven by `raw/feedback/` |

---

## 8. Project-specific lint checklist (add to `CLAUDE.md` when it proves useful)

- Every feature page has acceptance criteria, and each one is ticked, open, or explicitly dropped.
- Every component page lists real file paths that still exist in `app/`.
- No code path modifies a file in `sources/` (enforces [[d003-non-destructive-model]]).
- Real-time audio code has no allocation, locks, or file I/O ([[audio-latency]]).
- Every OPEN decision has a next step and an owner.
- Every dependency in `app/` is permissive-licensed and listed in `THIRD_PARTY_NOTICES.md` ([[d004-licence]]).
- Concepts named on 2+ pages but without their own page → create them.
- Sources ingested but cited by zero pages → re-check or note why.

---

## 9. Open questions for you (answer, and the agent files them into `raw/ideas/`)

1. ~~**Platform:**~~ ✅ Answered 2026-10-26: both iOS and Android → d001 accepted.
2. ~~**Material:**~~ ✅ Answered 2026-10-26: anything (voice, instruments, noise for sampling) → [[recording-diverse-material]], [[sampling-tools]].
3. ~~**Real-time vs render:**~~ ✅ Answered 2026-10-26: a short render is fine → render-then-play.
4. ~~**Licensing:**~~ ✅ Answered 2026-10-26: open source → d002 accepted. App licence: **Apache-2.0** → [[d004-licence]] accepted.
5. ~~**Loop/overdub:**~~ ✅ Answered 2026-10-26: yes, core feature → [[loop-pedal]], M5.
6. ~~**Looper feel:**~~ ✅ Answered 2026-10-26: free-length by default, with a tempo-sync option → [[loop-pedal]].
7. ~~**App name:**~~ ✅ Answered 2026-10-26: **Pocket Studio** is the final name.
