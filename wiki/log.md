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
