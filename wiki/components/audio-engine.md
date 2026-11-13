---
type: component
status: active
updated: 2026-11-13
sources: [raw/plan/pocket-studio-plan.md]
tags: [cpp, realtime, m0, m1]
---
# Audio engine

## Responsibility
Owns the device, the record tap, playback of the rendered edit list, and the transport (play/pause/seek/loop). Also hosts the looper ([[d005-loop-engine]]): a sample-accurate loop clock, a layer mixer, and full-duplex record-while-playing with latency offset ([[latency-compensation]]). Real-time safe ([[audio-latency]]).

**M0 state:** one playback device (48 kHz, stereo, f32, low-latency profile) playing a test sine ("hello tone").

**M1 state (in progress):** engine runs output-only or full duplex (mic + output); recorder and player done and host-tested; real-mic recording verified on the macOS host; awaiting iPhone verification.
- *Modes:* `ps_engine_start_ex(1)` opens one duplex device (mono f32 capture → input stage/recorder; stereo f32 output). The app opens the mic only on the Record screen (and closes it when the app is hidden while not recording), so the OS recording indicator is honest.
- *iOS session* is owned by `platform_apple.mm`, not miniaudio: PlayAndRecord + **measurement mode** (no voice processing, [[recording-diverse-material]]) + DefaultToSpeaker + AllowBluetoothA2DP; Playback when output-only. Mic permission via AVAudioApplication (iOS 17+) / AVAudioSession. Background recording via `UIBackgroundModes: audio`.
- *Interruptions* (calls, Siri): Core Audio stops the device; on interruption-ended the engine reactivates the session and restarts it. A take in progress keeps going with a gap; the Record screen tells the user.
- *Android:* AAudio input preset UNPROCESSED, falling back to VOICE_RECOGNITION if the device refuses. Permission and a `microphone`-type foreground service live in the app shell (`MainActivity.kt`, `RecordingService.kt`). **Unverified — no Android phone yet.**
- *Player:* streams one take from disk via a reader thread and a lock-free ring (2^17 floats ≈ 2.7 s), mixed into the output on every channel. Play/pause ramp over 5 ms ([[crossfades-and-clicks]]). Length comes from the file size when the header lags, so a crash-cut take plays in full. Seek restarts the reader (M2 will refine, [[playback-and-scrub]]).
- *Input stage* (audio thread): smoothed input gain (~5 ms one-pole, snaps to target within 0.01% so unity stays bit-exact), peak level meter, sticky clip flag. Runs on every input buffer, recording or not.
- *Recorder:* while a take is recording and not paused, the audio thread copies post-gain samples into a lock-free SPSC ring (2^19 floats ≈ 10.9 s). A writer thread drains it every 10 ms into a mono 32-bit float WAV ([[d007-recording-format]]), builds min/max peaks per 256 frames ([[waveform-rendering]]) and patches the WAV header after each new second of audio, so a crash loses at most ~1 s. Ring overflow is counted as dropped frames (target: 0).
- *Peaks file* (`peaks/*.bin`, [[storage]]): `"PSPK"` · u32 version 1 · u32 block frames (256) · u32 block count · count × (f32 min, f32 max), little-endian.

## Public interface
C API in `app/packages/pocket_audio/src/pocket_audio.h`, wrapped by the Dart class `PocketAudio` in `app/packages/pocket_audio/lib/pocket_audio.dart`:

| C | Dart | Notes |
|---|---|---|
| `ps_version()` | `PocketAudio.version` | "0.1.0 (miniaudio 0.11.25)" |
| `ps_engine_start()` | `PocketAudio.start()` | opens default output; throws `PocketAudioException` |
| `ps_engine_stop()` | `PocketAudio.stop()` | idempotent |
| `ps_engine_is_running()` / `ps_engine_sample_rate()` / `ps_engine_callback_count()` | getters | status for UI and tests |
| `ps_tone_set(hz, amp)` | `PocketAudio.setTone()` | lock-free; amplitude slew-limited (full scale per 10 ms) so it never clicks ([[crossfades-and-clicks]]) |
| `ps_tone_render_offline(...)` | `PocketAudio.renderToneOffline()` | device-free rendering for tests |
| `ps_input_process(mono, frames)` | `PocketAudio.processInput()` | the audio callback's entry point; tests call it to record without a mic |
| `ps_input_set_gain` / `ps_input_take_peak_level` / `ps_input_clipped` / `ps_input_reset_clip` | `inputGain`, `takeInputPeak()`, `clipped`, `resetClip()` | input stage |
| `ps_recorder_begin(path, sr)` / `ps_recorder_end(peaks_path)` | `beginRecording()` / `endRecording()` | `PS_ERROR_FILE`, `PS_ERROR_NOT_RECORDING`, `PS_ERROR_ALREADY_RUNNING` |
| `ps_recorder_set_paused` / `is_paused` / `is_recording` | `paused`, `isPaused`, `isRecording` | pause keeps metering; resume appends |
| `ps_recorder_frames_written` / `dropped_frames` / `write_error` | getters | `write_error` = disk error or 4 GiB limit |
| `ps_recorder_copy_peaks` / `peak_block_count` / `ps_peaks_block_frames` | `copyLivePeaks()`, `livePeakBlockCount`, `peakBlockFrames` | live waveform |
| `ps_engine_start_ex(with_input)` / `ps_engine_has_input` | `start(input:)`, `hasInput` | `PS_ERROR_NO_PERMISSION` if the mic is not granted (iOS) |
| `ps_engine_interruption_count` | `interruptionCount` | OS interruptions since launch |
| `ps_mic_permission` / `ps_mic_request_permission` | `micPermission`, `requestMicPermission()` | `PS_MIC_UNDETERMINED/GRANTED/DENIED`; Android reports granted (shell asks) |
| `ps_player_open/close/set_playing/is_playing/finished/seek/position/length` | `openTake()`, `closeTake()`, `playing`, `isPlaying`, `playbackFinished`, `seek()`, `playbackPosition`, `takeLength` | one take at a time |
| `ps_player_render_offline` | `renderPlayerOffline()` | tests: player's audio-thread code without a device |
| `ps_peaks_build(wav, peaks)` | `buildPeaks()` | rebuild peaks after a crash; run off the UI thread |

Threading: control calls take a mutex that the audio callback never touches; the callback reads only atomics and does no allocation, locking or I/O.

## Files in app/
- `app/packages/pocket_audio/src/pocket_audio.h` — C API (ffigen input)
- `app/packages/pocket_audio/src/engine.cpp` — device lifecycle + data callback
- `app/packages/pocket_audio/src/tone_generator.h` — real-time-safe sine generator
- `app/packages/pocket_audio/src/ring_buffer.h` — lock-free SPSC float ring
- `app/packages/pocket_audio/src/wav_writer.h` / `wav_writer.cpp` — streaming float WAV writer, crash-safe header
- `app/packages/pocket_audio/src/recorder.h` / `recorder.cpp` — input stage, recorder, writer thread, peaks
- `app/packages/pocket_audio/src/player.h` / `player.cpp` — streaming take player, WAV probe, peaks rebuild
- `app/packages/pocket_audio/src/platform.h`, `platform_apple.mm`, `platform_other.cpp` — iOS audio session + mic permission; no-ops elsewhere
- `app/lib/audio/audio_control.dart` — engine mode, mic permission (iOS via FFI, Android via channel), Android service
- `app/lib/screens/record_screen.dart`, `take_screen.dart`, `app/lib/main.dart` (takes list) — M1 UI
- `app/android/app/src/main/kotlin/dev/pocketstudio/pocket_studio/MainActivity.kt`, `app/android/app/src/main/kotlin/dev/pocketstudio/pocket_studio/RecordingService.kt` — Android permission + foreground service
- `app/packages/pocket_audio/src/miniaudio_impl.cpp` / `app/packages/pocket_audio/src/miniaudio_impl.mm` — miniaudio implementation unit (C++ / Objective-C++ on Apple)
- `app/packages/pocket_audio/src/third_party/miniaudio/` — vendored miniaudio 0.11.25
- `app/packages/pocket_audio/hook/build.dart` — native build ([[d006-native-build]])
- `app/packages/pocket_audio/lib/pocket_audio_bindings_generated.dart` — generated bindings
- `app/packages/pocket_audio/test/` — offline tone tests; `recorder_test.dart` (bit-exact WAV + peaks, pause/resume, crash-safe header, gain/meter/clip, 30-min run at 100× real time); `player_test.dart` (fade-in, pause holds position, end/finished, seek, crash-cut take, rebuilt peaks); `engine_device_test.dart` (tag `device`, skipped by default: output callbacks + 2 s real-mic take). Test files run one at a time (`dart_test.yaml`: the engine is process-global).
- `app/lib/main.dart` — M0 hello-tone screen + Licences screen

## Dependencies
miniaudio ([[d001-platform-and-stack]], [[d004-licence]]); build via [[d006-native-build]]. App: `path_provider` (Flutter team, BSD-3) for the documents folder; Android: `androidx.core`.

## Verified
- 2026-10-26, macOS host: core compiles through the build hook; offline tone tests pass; `engine_device_test` opened the real Core Audio output and received callbacks; Flutter widget test reads the version over FFI.
- 2026-11-13, CI: core compiles and links for Android (debug APK) and iOS (unsigned build); host tests pass on Linux.
- 2026-11-13, real iPhone 16 Pro Max (iOS 26.6.2), release build: tone audible; A3/A4/A5 pitch and volume slider change live; callback count keeps rising.
- 2026-11-13, macOS host: recorder tests pass (14/14), including 30 min of audio at 100× real time with 0 dropped frames and every sample bit-exact.
- 2026-11-13, macOS host: 21/21 core tests + 3 app tests pass; device test recorded 2 s from the real Mac mic (95,520 frames, 0 dropped).
- Not yet verified: hello tone on a real Android phone; recording on the iPhone.
