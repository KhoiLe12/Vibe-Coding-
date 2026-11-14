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

## [2026-10-26] build | M0 bootstrap: repo, wiki, legal, Flutter + C++ core, hello tone
- pages touched: [[audio-engine]], [[d006-native-build]], [[d004-licence]], [[d001-platform-and-stack]], [[overview]], [[index]]
- notes: split the plan into `CLAUDE.md` + wiki; filed the four §9 answers as raw/ideas/. Flutter 3.47.8 app + `pocket_audio`
  package_ffi core (miniaudio 0.11.25 vendored). macOS host: core tests, device test and widget test pass. Android/iOS untested (no SDKs here).

## [2026-10-26] lint | End of M0 bootstrap
- pages touched: [[tempo]], [[undo-history]], [[export]]
- notes: `tools/wiki_lint.py` 0 errors. Open findings for the human: tempo/undo-history/export lack acceptance criteria;
  [[q-transpose-scope]] still open (needed before M4); copyright holder and app bundle id are placeholders. Next source to ingest: Signalsmith Stretch docs.

## [2026-11-13] build | Repo published; first CI run green
- pages touched: [[overview]], [[d001-platform-and-stack]], [[audio-engine]]
- notes: pushed to github.com/KhoiLe12/Vibe-Coding- (main). CI: wiki-lint, tests, Android APK and iOS build all pass.
  Only M0 item left: hello tone on a real iPhone and Android phone.

## [2026-11-13] build | Hello tone verified on a real iPhone
- pages touched: [[overview]], [[audio-engine]]
- notes: iPhone 16 Pro Max, iOS 26.6.2, Xcode 27.2, free Apple ID (Personal Team), `flutter run --release`. Human confirmed the tone,
  pitch steps and volume all work. Only M0 item left: the same on a real Android phone.

## [2026-11-13] decision | Android phone check deferred
- pages touched: [[overview]]
- notes: Human has no Android phone on hand. M0's exit criteria (lint, CI on both platforms) are met, so work moves to M1.
  The real-Android hello-tone check stays open and must be done before M1 is marked done.

## [2026-11-13] decision | M1 recording format: mono, 32-bit float WAV, pre-roll later
- pages touched: [[d007-recording-format]], [[record]], [[index]]
- notes: Human picked all three recommended options while planning M1.

## [2026-11-13] build | M1 step 1: recorder core (host-tested)
- pages touched: [[audio-engine]], [[storage]]
- notes: Ring buffer, streaming float WAV writer with crash-safe header, writer thread, live/stored peaks, input gain/meter/clip.
  14/14 host tests incl. 30 min @100x, bit-exact. Found and fixed: smoothed gain stalled at 1.00001 and never returned to exact unity.

## [2026-11-13] build | M1 steps 2–3: mic, iOS session, player, screens
- pages touched: [[audio-engine]], [[storage]], [[waveform-view]]
- notes: Duplex engine, iOS measurement-mode session + permission + background audio + interruption restart, Android shell (unverified),
  streaming player, takes list / Record / Take screens. 21 core + 3 app tests pass; 2 s real-mic take on the Mac. Installed on iPhone.

## [2026-11-13] build | iPhone M1 tests; basic seeking pulled forward
- pages touched: [[record]], [[playback-and-scrub]]
- notes: Human: quick test and background test pass, stop→editor < 300 ms every time; 15-min take recorded. Couldn't skip around a
  long take, so tap/drag-to-seek + ±5 s buttons were added early. 30-min run still open.

## [2026-11-13] build | M1 done on iOS; Android verification open
- pages touched: [[record]], [[overview]]
- notes: Human: 30-min iPhone take passed. All M1 criteria verified on iOS. CI run 43466417419 green (lint, tests, Android APK incl. new Kotlin, iOS). No Android phone is available, so the Android checks
  (M0 hello tone, M1) stay open in [[overview]]. This replaces the earlier rule that they block M1; d001 is unchanged, CI still builds Android.

## [2026-11-14] decision | M2 latency gate measured on built-in speaker + mic
- pages touched: [[d008-latency-gate-route]], [[d001-platform-and-stack]], [[audio-latency]], [[overview]], [[index]]
- notes: Human has no wired headphones (USB-C iPhone, no adapter) and chose the speaker+mic measurement as the final gate route.
  Target (≤ 30 ms, no drift over 10 min) unchanged; Android half still open.

## [2026-11-14] decision | Tape-style scrubbing
- pages touched: [[d009-scrub-style]], [[playback-and-scrub]], [[index]]
- notes: Human picked tape-style over snippet-style. M2 starts with the latency gate, since it can change the engine.

## [2026-11-14] build | M2: latency probe + Latency test screen
- pages touched: [[audio-latency]], [[audio-engine]]
- notes: Chirp + cross-correlation probe in the audio callback; 29 core tests pass (simulated room exact to the sample, misses
  instead of wrong values in noise). Drift threshold set at 1 ms. Installed on iPhone for the gate run.

## [2026-11-14] build | Latency gate: 87.5 ms on iPhone; buffer-size experiment
- pages touched: [[audio-latency]]
- notes: Human measured a constant 87.5 ms. Traced to miniaudio's iOS duplex buffering (10 ms period override + 2-period ring padding).
  Added a period-size picker and granted-buffer readout to the Latency screen to measure the effect.

## [2026-11-14] build | Latency: 22.1 ms at 64-frame periods
- pages touched: [[audio-latency]]
- notes: Default 87.4 ms vs 64 frames 22.1 ms ⇒ ≈ 7 periods + 12.8 ms fixed. Under target only at 64. Next: 10-min drift run at 64, crackle check.

## [2026-11-14] decision | iOS latency gate passed; 64-frame duplex buffers
- pages touched: [[d010-duplex-buffer-size]], [[d001-platform-and-stack]], [[audio-latency]], [[overview]], [[index]]
- notes: Human's 10-min run at 64 frames: median 22.1 ms, drift 0, no crackling, one 148 ms outlier. iOS keeps miniaudio.
  Mic-open paths now use 64-frame periods; playback stays at the default. Needs a recording re-check at 64 frames.

## [2026-11-14] build | Recording re-checked at 64-frame buffers
- pages touched: [[d010-duplex-buffer-size]]
- notes: Human recorded several minutes (incl. locked phone) at 64 frames: no lost audio, clean playback.

## [2026-11-14] build | M2 navigation: mapped player, tape scrub, shuttle, loops, zoom
- pages touched: [[d011-mapped-player]], [[d010-duplex-buffer-size]], [[audio-engine]], [[waveform-view]], [[playback-and-scrub]], [[index]]
- notes: Player rebuilt on mmap + prefetch. 37 core tests (loop period exact, no clicks at wraps/seeks, scrub without overshoot —
  found and fixed an underdamped chase). Take screen gestures. Playback buffers 512→256 for the 50 ms start criterion. CI green for 6a57282.

## [2026-11-14] build | Scrub reworked after iPhone feedback
- pages touched: [[d009-scrub-style]], [[playback-and-scrub]]
- notes: Absolute finger→frame mapping made zoomed-out scrubs race at 8× and jump on release. Now relative with a 10 ms/px cap,
  and release stays where the tape is. 38 core tests pass.

## [2026-11-14] build | M2 done on iOS
- pages touched: [[playback-and-scrub]], [[overview]]
- notes: Human confirmed reworked scrub (clear at ~real-time drags, stays put on release); all M2 criteria ticked
  (start latency is an estimate, noted). Android gate half stays open.

## [2026-11-14] decision | M3 chop model
- pages touched: [[d012-chop-model]], [[chop]], [[index]]
- notes: Human chose edit-in-place (with revert). Snapshot undo, 10 ms equal-power joins, ±5 ms zero-crossing snap, clip list saved per take.

## [2026-11-14] build | M3 chop built
- pages touched: [[edit-model]], [[audio-engine]], [[storage]], [[chop]]
- notes: Timeline playback with 10 ms equal-power joins and zero-crossing snap; EditList/EditHistory; per-take edits JSON;
  take screen editing UI. 45 core + 15 app tests pass. Installed on iPhone for checking.

## [2026-11-14] build | M3 iPhone check + usability fixes
- pages touched: [[chop]]
- notes: Human: no clicks, undo/redo correct, live edits smooth, edits persist. Added jump-to-selection-start, block selection
  via the clip strip, zoom-out on duplicate; fixed the zoom state after undo/trim/duplicate.

## [2026-11-14] build | M3 done on iOS
- pages touched: [[chop]], [[undo-history]], [[overview]]
- notes: Human confirmed the usability fixes (zoom after trim/undo, block selection, jump to start). Both chop criteria ticked;
  undo-history gained criteria (session undo ✓, persisted history → M7).

## [2026-11-14] decision | Transpose applies to the whole take (M4)
- pages touched: [[q-transpose-scope]]
- notes: Human chose whole-take transpose; per-clip stays in the backlog. CI run 43542562901 green for 4de0b32 (M3).

## [2026-11-14] decision | M4 transpose & tempo design
- pages touched: [[d013-transpose-tempo-design]], [[tempo]], [[transpose]], [[index]]
- notes: Human: tempo 75–150% (narrows the plan's 50–200%), formant off by default, approved tempo criteria.
  Signalsmith Stretch is at 1.4.0 (MIT) with formant compensation; it needs Signalsmith Linear.

## [2026-11-14] build | M4 transpose & tempo built
- pages touched: [[dsp-processor]], [[audio-engine]], [[storage]], [[transpose]], [[tempo]], [[d013-transpose-tempo-design]]
- notes: Vendored Signalsmith Stretch 1.4.0 + Linear 0.6.4 (MIT). Found presetDefault up to 12 cents sharp at -24 st → 240 ms blocks.
  Renderer, render cache, player sources, tune in the edit state, pitch/tempo sheet. 58 core + 23 app tests. Installed on iPhone.

## [2026-11-14] build | M4 done on iOS
- pages touched: [[transpose]], [[tempo]], [[overview]]
- notes: Human: renders 0.6–1 s, switch-over in place, formant toggle works to ±5 st, attacks crisp, UI responsive, editing while
  transposed fine. Mid-range render-speed criterion left open (only a high-end iPhone available).

## [2026-11-14] decision | Loop pedal M5a: speaker monitoring, scope split, engine design
- pages touched: [[d014-looper-m5a]], [[loop-pedal]], [[index]]
- notes: Human: speaker monitoring for now; split M5a/M5b. Bounce = mixdown into a new take until M7 (flagged deviation).
  CI run 43548790516 green for 6c30672 (M4), incl. Signalsmith on Linux/Android.

## [2026-11-14] build | M5a loop pedal built
- pages touched: [[audio-engine]], [[loop-pedal]], [[storage]]
- notes: Looper engine in the audio callback + screen + per-route calibration. Caught in review: stale layer buffers of an old loop
  length could be written past their end → buffers now length-tagged. 66 core + 24 app tests; one unexplained full-suite failure
  seen once, not reproduced in 30 reruns. Installed on iPhone.

## [2026-11-14] build | Loop pedal too quiet on iPhone → gains + meters
- pages touched: [[d014-looper-m5a]], [[loop-pedal]]
- notes: Human couldn't hear the loop. Real-device Mac test showed the engine works (-28.5 dBFS room noise recorded); a playback
  meter confirmed a level problem (no mic AGC + quieter speaker in measurement mode). Added mic gain / loop volume (+12 dB) and a limiter.

## [2026-11-14] build | Loop pedal: default iOS mode instead of +12 dB boosts
- pages touched: [[d014-looper-m5a]], [[recording-diverse-material]]
- notes: Human: still quiet below ~70 % volume and the mic clipped. Root cause is measurement mode disabling speaker loudness
  processing; the loop pedal now uses the default mode (no AEC/NS), gains back to 0 dB, calibration keyed per route+mode.

## [2026-11-14] decision | Layers (multitrack) inserted as M6; overdub = one layer per press
- pages touched: [[layers]], [[d015-layers]], [[loop-pedal]], [[overview]], [[index]], plus renumbered M6–M9 references
- notes: Human: "loop pedal" meant layering recordings. Chose both modes (record on top + add takes), sliding layers, recorded layers as
  takes, Layers next; loop pedal kept. Overdub fixed to one layer per press; looper gain smoothing made one-pole (was 1 s to come down).

## [2026-11-14] build | Loop pedal: overdub layers locked to the loop
- pages touched: [[loop-pedal]], [[d014-looper-m5a]]
- notes: Human: layers should start and record together. Overdub now arms, records exactly one pass from the loop start with a
  seam crossfade, adds itself; press again cancels. 70 core tests pass. Installed on iPhone.

## [2026-11-14] build | Loop pedal: Overdub restarts the loop; session-state leaks fixed
- pages touched: [[loop-pedal]], [[d014-looper-m5a]]
- notes: Human found the wait-for-loop-start countdown clunky. Overdub now restarts the loop at once and records one pass.
  Tests exposed two leaks across sessions (restart fade could read past a shorter loop; smoothed gains). 71 core tests pass 3×.

## [2026-11-14] build | M5a done on iOS; delete any loop layer
- pages touched: [[loop-pedal]], [[overview]]
- notes: Human verified restart, timing, bounce, 10 layers, undo. Added per-layer delete (fade then remove, first take mute-only).
  72 core + 24 app tests. Mid-range 20-layer check stays open.

## [2026-11-14] build | M6 Layers built
- pages touched: [[layers]], [[audio-engine]], [[storage]], [[edit-model]]
- notes: Multi-track player (tracks + offsets + smoothed volumes + edge fades), stack bounce, recorder start stamp, offline full
  callback; LayerStack model + History<T>; stack screen; home lists stacks. 78 core + 29 app tests. Installed on iPhone.

## [2026-11-14] build | Layers: bounce fix, stable lanes, snapping, edit a layer's take
- pages touched: [[layers]]
- notes: Human: lining up was hard (waveforms shifted on drop), bounce failed (unsendable closure). Fixed both; added snapping + 1 s
  grid and per-layer editing via the take editor. Stack-wide editing awaits the human's answer.

## [2026-11-14] build | Layers: edit the whole stack; bounce from the editor
- pages touched: [[layers]]
- notes: Human wants stack-wide edits. The arrangement is mixed into a hashed cache file and opened in the take editor; stack edits
  are keyed by stack id and clamped to shorter mixes. Editor gained Bounce. 31 app tests pass. Installed on iPhone.

## [2026-11-14] build | Layers: snap the sound start; grid over the lanes
- pages touched: [[layers]]
- notes: Human needed to line up where the sound starts, and couldn't see the grid. Added a sound-start marker that snaps (preferred
  over the file start) and drew the grid on top. 32 app tests. Installed on iPhone.

## [2026-11-14] build | Layers: snap toggle
- pages touched: [[layers]]
- notes: Human asked to be able to turn magnetic snapping off; grid icon in the stack screen's top bar.

## [2026-11-14] build | Layers: no automatic re-alignment to 0:00
- pages touched: [[layers]], [[d015-layers]]
- notes: Human found the earliest-layer-to-0 rule annoying and wants leading silence. Offsets now stay as placed (clamped at 0).

## [2026-11-14] build | Audio start retried on play and resume
- pages touched: [[layers]]
- notes: Human: stack sometimes silent when opened right after launch. Likely iOS refusing session activation during launch; play
  and app-resume now ensure the engine runs (one retry), with a message on failure. Not reproduced on the Mac.

## [2026-11-14] build | Stalled audio after app switching: liveness check + restart
- pages touched: [[layers]], [[audio-engine]]
- notes: Human: silent after tabbing to another app and back, no message. iOS interruption without an "ended" notice left the engine
  flagged running but stopped. Play/resume now verify callbacks advance and restart the engine if not.

## [2026-11-14] build | Layers: stalled-audio fix confirmed; lining up confirmed
- pages touched: [[layers]]
- notes: Human confirmed audio after app switching and that lining up feels great. Open checks: recorded-layer timing, undo, 8 layers,
  bounce after the fix, per-layer and whole-stack editing.

## [2026-11-14] build | M6 Layers verified on iOS (bounce check pending)
- pages touched: [[layers]], [[overview]]
- notes: Human: recorded-layer alignment, undo, 8 layers, per-layer and whole-stack editing all work. Bounce not yet confirmed on device.
