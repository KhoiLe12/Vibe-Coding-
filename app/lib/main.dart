// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocket_audio/pocket_audio.dart';

void main() {
  LicenseRegistry.addLicense(_thirdPartyLicences);
  runApp(const PocketStudioApp());
}

/// Licences of bundled native code (THIRD_PARTY_NOTICES.md). Flutter's own
/// packages register theirs automatically.
Stream<LicenseEntry> _thirdPartyLicences() async* {
  final miniaudio = await rootBundle.loadString('assets/licenses/miniaudio.txt');
  yield LicenseEntryWithLineBreaks(['miniaudio'], miniaudio);
}

class PocketStudioApp extends StatelessWidget {
  const PocketStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pocket Studio',
      theme: ThemeData(colorSchemeSeed: Colors.deepOrange, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.deepOrange,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HelloToneScreen(),
    );
  }
}

/// M0 smoke test: proves the Flutter UI drives the C++ core on a real device.
class HelloToneScreen extends StatefulWidget {
  const HelloToneScreen({super.key});

  @override
  State<HelloToneScreen> createState() => _HelloToneScreenState();
}

class _HelloToneScreenState extends State<HelloToneScreen> {
  static const _notes = {'A3': 220.0, 'A4': 440.0, 'A5': 880.0};

  String _note = 'A4';
  double _amplitude = 0.2;
  bool _playing = false;
  String? _error;
  Timer? _statusTimer;

  @override
  void dispose() {
    _statusTimer?.cancel();
    PocketAudio.stop();
    super.dispose();
  }

  void _applyTone() => PocketAudio.setTone(
        frequencyHz: _notes[_note]!,
        amplitude: _playing ? _amplitude : 0,
      );

  void _toggle() {
    setState(() {
      _error = null;
      if (_playing) {
        _playing = false;
        _applyTone(); // ramps down; the device keeps running
        return;
      }
      try {
        if (!PocketAudio.isRunning) PocketAudio.start();
        _playing = true;
        _applyTone();
        _statusTimer ??= Timer.periodic(
          const Duration(milliseconds: 250),
          (_) => setState(() {}),
        );
      } on PocketAudioException catch (e) {
        _error = e.message;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pocket Studio'),
        actions: [
          IconButton(
            tooltip: 'Licences',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'Pocket Studio',
              applicationLegalese:
                  'Copyright 2026 The Pocket Studio Authors\n'
                  'Licensed under the Apache License 2.0',
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Hello tone', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text('Audio core ${PocketAudio.version}',
                  style: theme.textTheme.bodySmall),
              const Spacer(),
              Center(
                child: SizedBox.square(
                  dimension: 160,
                  child: FilledButton(
                    key: const Key('toggle'),
                    style: FilledButton.styleFrom(shape: const CircleBorder()),
                    onPressed: _toggle,
                    child: Icon(_playing ? Icons.stop : Icons.play_arrow,
                        size: 72),
                  ),
                ),
              ),
              const Spacer(),
              SegmentedButton<String>(
                segments: [
                  for (final note in _notes.keys)
                    ButtonSegment(value: note, label: Text(note)),
                ],
                selected: {_note},
                onSelectionChanged: (s) {
                  setState(() => _note = s.single);
                  _applyTone();
                },
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(Icons.volume_down),
                  Expanded(
                    child: Slider(
                      value: _amplitude,
                      max: 0.5,
                      onChanged: (v) {
                        setState(() => _amplitude = v);
                        _applyTone();
                      },
                    ),
                  ),
                  const Icon(Icons.volume_up),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _error ??
                    (PocketAudio.isRunning
                        ? '${PocketAudio.sampleRate} Hz · '
                            '${PocketAudio.callbackCount} callbacks'
                        : 'Engine stopped'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: _error != null ? theme.colorScheme.error : null),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
