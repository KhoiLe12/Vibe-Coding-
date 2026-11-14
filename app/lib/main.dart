// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'screens/latency_screen.dart';
import 'screens/record_screen.dart';
import 'screens/take_screen.dart';
import 'takes/take_store.dart';
import 'widgets/waveform.dart';

void main() {
  LicenseRegistry.addLicense(_thirdPartyLicences);
  runApp(PocketStudioApp(openStore: _openDefaultStore));
}

Future<TakeStore> _openDefaultStore() async {
  final docs = await getApplicationDocumentsDirectory();
  return TakeStore(Directory('${docs.path}/projects/inbox'));
}

/// Licences of bundled native code (THIRD_PARTY_NOTICES.md). Flutter's own
/// packages register theirs automatically.
Stream<LicenseEntry> _thirdPartyLicences() async* {
  final miniaudio = await rootBundle.loadString(
    'assets/licenses/miniaudio.txt',
  );
  yield LicenseEntryWithLineBreaks(['miniaudio'], miniaudio);
}

class PocketStudioApp extends StatelessWidget {
  const PocketStudioApp({super.key, required this.openStore});

  final Future<TakeStore> Function() openStore;

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
      home: TakesScreen(openStore: openStore),
    );
  }
}

/// Home: the list of takes, newest first, and the record button.
class TakesScreen extends StatefulWidget {
  const TakesScreen({super.key, required this.openStore});

  final Future<TakeStore> Function() openStore;

  @override
  State<TakesScreen> createState() => _TakesScreenState();
}

class _TakesScreenState extends State<TakesScreen> {
  TakeStore? _store;
  List<Take> _takes = const [];

  @override
  void initState() {
    super.initState();
    widget.openStore().then((store) {
      if (!mounted) return;
      _store = store;
      _refresh();
    });
  }

  void _refresh() => setState(() => _takes = _store?.list() ?? const []);

  Future<void> _push(Widget screen) async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pocket Studio'),
        actions: [
          IconButton(
            key: const Key('latency'),
            tooltip: 'Latency test',
            icon: const Icon(Icons.speed),
            onPressed: () => _push(const LatencyScreen()),
          ),
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
      body: store == null
          ? const Center(child: CircularProgressIndicator())
          : _takes.isEmpty
          ? Center(
              child: Text(
                'No takes yet.\nTap the red button to record.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 120),
              itemCount: _takes.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final take = _takes[i];
                return ListTile(
                  leading: const Icon(Icons.graphic_eq),
                  title: Text(takeTitle(take)),
                  subtitle: take.edited ? const Text("Edited") : null,
                  trailing: Text(
                    formatDuration(take.duration),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  onTap: () => _push(TakeScreen(store: store, take: take)),
                );
              },
            ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: store == null
          ? null
          : SizedBox.square(
              dimension: 80,
              child: FloatingActionButton.large(
                key: const Key('new-take'),
                tooltip: 'Record',
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
                shape: const CircleBorder(),
                onPressed: () => _push(RecordScreen(store: store)),
                child: const Icon(Icons.mic, size: 40),
              ),
            ),
    );
  }
}
