// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Builds the C++ audio core (src/) into one dynamic library per target.
///
/// Apple targets compile miniaudio as Objective-C++ (it calls AVAudioSession
/// on iOS) and link the audio frameworks directly instead of miniaudio's
/// runtime linking, which can fail App Store notarization. Other targets
/// compile everything as C++. See wiki/components/audio-engine.md.
void main(List<String> args) async {
  await build(args, (input, output) async {
    final packageName = input.packageName;
    final targetOS = input.config.code.targetOS;
    final isApple = targetOS == OS.iOS || targetOS == OS.macOS;

    final cbuilder = CBuilder.library(
      name: packageName,
      assetName: '${packageName}_bindings_generated.dart',
      sources: [
        'src/engine.cpp',
        'src/dsp_processor.cpp',
        'src/latency_probe.cpp',
        'src/looper.cpp',
        'src/player.cpp',
        'src/recorder.cpp',
        'src/wav_writer.cpp',
        isApple ? 'src/miniaudio_impl.mm' : 'src/miniaudio_impl.cpp',
        isApple ? 'src/platform_apple.mm' : 'src/platform_other.cpp',
      ],
      // Signalsmith Stretch includes "signalsmith-linear/stft.h".
      includes: ['src', 'src/third_party/signalsmith/linear/include'],
      std: 'c++17',
      // Objective-C mode lets clang pick the language per file extension
      // (.cpp / .mm); it does not link libc++ on its own.
      language: isApple ? Language.objectiveC : Language.cpp,
      libraries: [
        if (isApple) 'c++',
        if (targetOS == OS.linux) ...['m', 'pthread', 'dl'],
      ],
      frameworks: [
        if (isApple) ...[
          'Foundation',
          'CoreFoundation',
          'CoreAudio',
          'AudioToolbox',
          'Accelerate', // FFTs for Signalsmith Stretch
        ],
        if (targetOS == OS.iOS) 'AVFoundation',
      ],
      defines: {
        if (isApple) 'MA_NO_RUNTIME_LINKING': null,
        if (isApple) 'SIGNALSMITH_USE_ACCELERATE': null,
        // Pocket Studio does its own decoding and processing.
        'MA_NO_GENERATION': null,
        'MA_NO_NODE_GRAPH': null,
        'MA_NO_ENGINE': null,
        'MA_NO_RESOURCE_MANAGER': null,
      },
    );
    await cbuilder.run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = Level.ALL
        // ignore: avoid_print
        ..onRecord.listen((record) => print(record.message)),
    );
  });
}
