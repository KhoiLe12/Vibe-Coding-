# pocket_audio

Pocket Studio's C++17 audio core, exposed to Dart through `dart:ffi`.

- `src/pocket_audio.h`: C API (source for the generated bindings)
- `src/engine.cpp`: device + real-time callback (miniaudio)
- `src/tone_generator.h`: M0 test tone (real-time safe)
- `src/third_party/miniaudio/`: vendored miniaudio 0.11.25 (public domain / MIT-0)
- `hook/build.dart`: compiles `src/` for each target with `native_toolchain_c`

Regenerate bindings after changing the header:

    dart run ffigen --config ffigen.yaml

See `wiki/components/audio-engine.md`.
