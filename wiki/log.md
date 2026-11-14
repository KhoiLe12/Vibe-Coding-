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
