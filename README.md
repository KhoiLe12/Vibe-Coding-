# Pocket Studio

Record audio and edit it on the spot: chop, scrub, transpose and loop, on iOS
and Android. Open source under Apache-2.0.

**Status:** Milestones 1–4, loop pedal part one (M5a) and Layers (M6) done on
iOS; working on M7 (sampling tools). Android builds in CI but is not yet tested
on a phone. See `wiki/overview.md` for the roadmap.

## Layout

| Path | What |
|---|---|
| `CLAUDE.md` | Schema for the agent that maintains the wiki and code |
| `raw/` | Immutable sources: the plan, library docs, ideas, feedback |
| `wiki/` | Knowledge base: features, concepts, components, decisions (start at `wiki/index.md`) |
| `app/` | Flutter app (`pocket_studio`) |
| `app/packages/pocket_audio/` | C++17 audio core (miniaudio) + Dart FFI bindings, built by a Dart build hook |
| `tools/wiki_lint.py` | Mechanical wiki checks, run in CI |

## Build

Requires Flutter 3.47.8 (stable), plus Xcode for iOS and the Android SDK/NDK
for Android.

    cd app
    flutter pub get
    flutter run            # on a connected iPhone or Android phone

Tests:

    (cd app/packages/pocket_audio && dart test)                         # core, no device needed
    (cd app/packages/pocket_audio && dart test --run-skipped -t device) # opens the real output device
    (cd app && flutter test)

See `CONTRIBUTING.md` for the licence of contributions.
