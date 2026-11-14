# Pocket Studio

Record sounds on your phone and turn them into music on the spot: chop, scrub,
transpose, loop, layer, and export samples ready for a DAW. Open source under
Apache-2.0.

Pocket Studio is a small studio built around the microphone. Record a voice, a
guitar, a door slam or a whole song, then cut it up, change its pitch and
speed, stack takes on top of each other, play it on a loop pedal, and send
clean WAV samples to FL Studio, Ableton, Logic or a sampler.

**Status:** finished for iOS and tested on an iPhone 16 Pro Max. Android
builds in CI but has not been tried on a real phone yet. There is no App Store
or Play Store release: you install it by building it (see
[Download and install](#download-and-install)).

## Features

- **Record:** mono 48 kHz, 32-bit float, with no voice processing, so noises
  and instruments come out as they sound. Live waveform, level meter with clip
  light, input gain, and background recording. Optional tempo with a clicked
  count-in.
- **Navigate:** tape-style scrubbing (drag the waveform), hold to
  rewind/fast-forward, pinch to zoom, and A–B loops.
- **Chop:** split, delete, trim, duplicate and reorder. Cuts are crossfaded,
  so they never click. Unlimited undo/redo, and nothing ever touches the
  original recording.
- **Pitch and tempo:** transpose ±24 semitones (with cents and a "keep voice
  natural" option) and stretch tempo 75–150 % without changing pitch.
- **Sampling tools:** reverse, fade in/out handles, normalize, trim silence,
  and tape-style varispeed.
- **Beat grid:** set or detect a BPM. Bar and beat lines appear, chops snap
  to beats, a click can play along, and you can play a take at a target BPM.
- **Layers:** stack takes into a multitrack and record new layers on top,
  lined up automatically. Slide layers with magnetic snapping, mix, and bounce.
- **Loop pedal:** record a loop and overdub layers that line up after a
  one-time latency calibration. Undo/mute/solo layers, tempo sync with
  count-in and exact-bar loops, a tape-style feedback mode, and bounce to a
  take.
- **Export:** one-shots, seamless loops (with loop points for samplers) or one
  file per slice, as 48 kHz/24-bit or 44.1 kHz/24- or 16-bit WAV, through the
  share sheet (AirDrop, Files, Mail…).

## How to use it

### The home screen
Your takes and stacks are listed newest first. Tap one to open it.
- **● (big red button):** record a new take.
- **Layers icon:** start a new stack.
- **∞:** the loop pedal.

### Recording
1. Tap **●** to start and **■** to stop. The take opens in the editor right
   away.
2. Set **Gain** so the meter stays out of the red. Tap the clip light to
   reset it.
3. **Record with tempo** (optional): tap the *No tempo* chip and set a BPM
   (type it, use ±, or **Tap** along), a time signature and a count-in. The
   count-in clicks, recording starts exactly on the downbeat, and while you
   record the beat is shown as lights, so the click isn't recorded. Turn on
   *Click while recording* if you use headphones.

### Editing a take
- **Play** with ▶; **drag** the waveform to scrub; **pinch** to zoom; **hold**
  ⏪/⏩ to rewind or fast-forward; **tap** to jump.
- **Select:** long-press and drag. The selection loops while you play. The bar
  under the waveform has Delete, Trim, Duplicate and loop on/off.
- **Split** (✂) at the playhead. Each piece becomes a clip in the strip below
  the waveform. Drag clips to reorder them; tap one to select it.
- **Pitch / Tempo / Varispeed** chips: semitones, cents, *Keep voice natural*,
  speed 75–150 %, and tape-style varispeed. Changes render in the background
  while playback continues.
- **✨ Sample tools:** Reverse, Remove fades, Normalize (to −1 dB) and Trim
  silence. They act on the selection, or on the whole take if nothing is
  selected.
- **Fades:** drag the small squares in the top corners of the waveform
  inward. They sit at the ends of the take, or of the selection if there is
  one.
- **BPM** chip: set the take's tempo, or tap **Detect** to find it from the
  audio. Use **½× / 2×** if it hears half or double time, and *Downbeat at
  playhead* if beat 1 is in the wrong place. With a tempo set, the ⋮ menu has
  *Snap to beats* and *Click with playback*.
- **Undo / redo** are at the top. ⋮ also has *Export samples…*, *Bounce to new
  take*, *Revert to original* and *Delete take*.

### Exporting samples
⋮ → **Export samples…**, then pick:
- **One-shot:** the selection or whole take, as you hear it.
- **Loop:** the same, with loop points, and the seam crossfaded so it loops
  without a click.
- **Slices:** one file per clip, so split first.

Choose a format and share. AirDrop to a Mac and drag the files into your DAW.

### Stacks (layers)
- **Add take** puts an existing take on a new lane. **Record layer** records
  on top while the stack plays, lined up for the phone's delay.
- **Slide** a lane sideways to move it. It snaps to other layers, the
  playhead, and beats (or seconds); the grid icon turns snapping off.
- Each layer has volume, mute, solo and remove. Tap a layer's name to edit its
  take.
- ⋮ has *Set tempo…*, *Click with playback*, *Edit whole stack* and *Bounce to
  new take*.

### Loop pedal
1. The first time, it calibrates the phone's audio delay. You'll hear a few
   chirps; keep the room quiet.
2. Tap **Record**, play, and tap **Close loop**. The loop plays right away.
3. Tap **Overdub** to add a layer. The loop restarts and records one full
   pass. Tap again to cancel.
4. **Undo/redo** the last layer at the top. Each layer has volume, mute, solo
   and delete.
5. **Tempo sync:** tap *Free* to set a BPM, signature and count-in. Record
   then counts in, and Close loop snaps to the nearest whole bar.
6. **Feedback:** older layers fade a little on every pass, like tape.
7. ⋮ → **Bounce to new take** (1–8 passes) turns the loop into a normal take
   you can edit and export.

Through the phone's speaker, the mic also records the loop into new layers.
Wired headphones avoid that. Bluetooth headphones add too much delay to line
layers up.

## Download and install

Pocket Studio isn't in the App Store or Play Store. You build it from this
repository and install it on your own phone.

### iPhone (iOS 15 or later)
You need a Mac with [Xcode](https://apps.apple.com/app/xcode/id497799835) and
[Flutter 3.47.8](https://docs.flutter.dev/get-started/install) (stable). A
free Apple ID is enough.

1. Get the code:

       git clone https://github.com/KhoiLe12/Vibe-Coding-.git pocket-studio
       cd pocket-studio/app
       flutter pub get

2. Set up signing once:
   - Open `ios/Runner.xcworkspace` in Xcode.
   - Select **Runner** → **Signing & Capabilities** and choose your **Team**
     (your Apple ID).
   - If Xcode complains about the bundle identifier, change
     `dev.pocketstudio.pocketStudio` to something unique, e.g.
     `com.yourname.pocketstudio`.
3. Connect your iPhone with a cable and unlock it. Turn on **Developer Mode**
   under Settings › Privacy & Security, which appears after the first
   attempt.
4. Build and install:

       flutter run --release

   If that fails to install, build first and then install with Xcode's tools:

       flutter build ios --release
       xcrun devicectl list devices      # find your phone's identifier
       xcrun devicectl device install app --device <identifier> build/ios/iphoneos/Runner.app

5. On the phone, trust the developer the first time: Settings › General ›
   VPN & Device Management.

With a free Apple ID, the app stops opening after 7 days. Run step 4 again to
renew it; your recordings stay. A paid developer account extends this to a
year.

### Android (untested on a phone)
- **Easiest:** every push to `main` builds a debug APK in GitHub Actions. Open
  the latest **CI** run under the repository's *Actions* tab, download
  `pocket-studio-debug-apk`, and install it on your phone. You'll need to
  allow installing unknown apps.
- **From source:** install Flutter and the Android SDK/NDK, plug in the phone
  with USB debugging on, then:

      cd app
      flutter run --release

Android has not been tested on a real device yet. Expect rough edges,
especially audio latency on the loop pedal.

## For developers

| Path | What |
|---|---|
| `app/` | Flutter app (`pocket_studio`) |
| `app/packages/pocket_audio/` | C++17 audio core (miniaudio, Signalsmith Stretch) and its Dart FFI bindings, built by a Dart build hook |
| `wiki/` | Design knowledge base: features, concepts, components, decisions. Start at `wiki/index.md` |
| `raw/` | Immutable sources: the plan, ideas, feedback |
| `CLAUDE.md` | Rules for the coding agent that maintains the wiki and code |
| `tools/wiki_lint.py` | Mechanical wiki checks, run in CI |

Tests:

    (cd app/packages/pocket_audio && dart test)                         # audio core, no device needed
    (cd app/packages/pocket_audio && dart test --run-skipped -t device) # opens the real audio device
    (cd app && flutter test)                                            # app
    python3 tools/wiki_lint.py

Real-time audio runs entirely in C++. Dart only sends commands and draws.
Code on the audio thread must not allocate, lock or touch files. See
`CONTRIBUTING.md` for how contributions are licensed and
`THIRD_PARTY_NOTICES.md` for the libraries used.

## Licence

Apache License 2.0. See `LICENSE` and `NOTICE`. Third-party components are
listed in `THIRD_PARTY_NOTICES.md`.
