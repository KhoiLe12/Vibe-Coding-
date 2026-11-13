---
type: component
status: active
updated: 2026-10-26
sources: [raw/plan/pocket-studio-plan.md]
tags: [cpp, realtime, m0]
---
# Audio engine

## Responsibility
Owns the device, the record tap, playback of the rendered edit list, and the transport (play/pause/seek/loop). Also hosts the looper ([[d005-loop-engine]]): a sample-accurate loop clock, a layer mixer, and full-duplex record-while-playing with latency offset ([[latency-compensation]]). Real-time safe ([[audio-latency]]).

**M0 state:** one playback device (48 kHz, stereo, f32, low-latency profile) playing a test sine ("hello tone"). No input, no transport yet.

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

Threading: control calls take a mutex that the audio callback never touches; the callback reads only atomics and does no allocation, locking or I/O.

## Files in app/
- `app/packages/pocket_audio/src/pocket_audio.h` — C API (ffigen input)
- `app/packages/pocket_audio/src/engine.cpp` — device lifecycle + data callback
- `app/packages/pocket_audio/src/tone_generator.h` — real-time-safe sine generator
- `app/packages/pocket_audio/src/miniaudio_impl.cpp` / `app/packages/pocket_audio/src/miniaudio_impl.mm` — miniaudio implementation unit (C++ / Objective-C++ on Apple)
- `app/packages/pocket_audio/src/third_party/miniaudio/` — vendored miniaudio 0.11.25
- `app/packages/pocket_audio/hook/build.dart` — native build ([[d006-native-build]])
- `app/packages/pocket_audio/lib/pocket_audio_bindings_generated.dart` — generated bindings
- `app/packages/pocket_audio/test/` — offline tone tests; `engine_device_test.dart` (tag `device`, skipped by default)
- `app/lib/main.dart` — M0 hello-tone screen + Licences screen

## Dependencies
miniaudio ([[d001-platform-and-stack]], [[d004-licence]]); build via [[d006-native-build]].

## Verified
- 2026-10-26, macOS host: core compiles through the build hook; offline tone tests pass; `engine_device_test` opened the real Core Audio output and received callbacks; Flutter widget test reads the version over FFI.
- Not yet verified: Android and iOS builds (CI), hello tone on real phones.
