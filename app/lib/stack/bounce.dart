// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:isolate';

import 'package:pocket_audio/pocket_audio.dart';

/// Mixes what the player has open (a stack, or a take with its edits and
/// pitch/tempo render) into a mono float WAV at [path] on a background
/// isolate, so the screen stays responsive.
///
/// Top-level on purpose: a closure created inside a State method captures
/// that method's whole context (including the State, which can't be sent to
/// another isolate) — that was the "object is unsendable" bounce failure.
Future<void> bounceStackInBackground(String path) =>
    Isolate.run(() => PocketAudio.bounceMix(path));
