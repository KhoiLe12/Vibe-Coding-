// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'screens/latency_screen.dart';
import 'screens/looper_screen.dart';
import 'screens/record_screen.dart';
import 'screens/stack_screen.dart';
import 'stack/stack.dart';
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
  for (final (name, file) in [
    ('Signalsmith Stretch', 'signalsmith-stretch'),
    ('Signalsmith Linear', 'signalsmith-linear'),
  ]) {
    final text = await rootBundle.loadString('assets/licenses/$file.txt');
    yield LicenseEntryWithLineBreaks([name], text);
  }
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
  List<LayerStack> _stacks = const [];
  Set<String> _inStacks = const {};

  @override
  void initState() {
    super.initState();
    widget.openStore().then((store) {
      if (!mounted) return;
      _store = store;
      _refresh();
    });
  }

  void _refresh() => setState(() {
    _takes = _store?.list() ?? const [];
    _stacks = _store?.listStacks() ?? const [];
    _inStacks = _store?.takesInStacks() ?? const {};
  });

  void _newStack() {
    final store = _store;
    if (store == null) return;
    _push(StackScreen(store: store, stack: store.newStack()));
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) _refresh();
  }

  Widget _header(String text, ThemeData theme) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(text, style: theme.textTheme.titleSmall),
  );

  static String _when(DateTime c) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${c.day}/${c.month} · ${two(c.hour)}:${two(c.minute)}';
  }

  Widget _takeTile(Take take, TakeStore store, ThemeData theme) {
    final notes = [
      if (take.edited) 'Edited',
      if (_inStacks.contains(take.id)) 'In a stack',
    ];
    return ListTile(
      leading: const Icon(Icons.graphic_eq),
      title: Text(takeTitle(take)),
      subtitle: notes.isEmpty ? null : Text(notes.join(' · ')),
      trailing: Text(
        formatDuration(take.duration),
        style: theme.textTheme.bodyLarge?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      onTap: () => _push(TakeScreen(store: store, take: take)),
    );
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
            key: const Key('new-stack'),
            tooltip: 'New stack (layers)',
            icon: const Icon(Icons.layers),
            onPressed: store == null ? null : _newStack,
          ),
          IconButton(
            key: const Key('looper'),
            tooltip: 'Loop pedal',
            icon: const Icon(Icons.all_inclusive),
            onPressed: store == null
                ? null
                : () => _push(LooperScreen(store: store)),
          ),
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
          : _takes.isEmpty && _stacks.isEmpty
          ? Center(
              child: Text(
                'No takes yet.\nTap the red button to record.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 120),
              children: [
                if (_stacks.isNotEmpty) ...[
                  _header('Stacks', theme),
                  for (final s in _stacks)
                    ListTile(
                      leading: const Icon(Icons.layers),
                      title: Text(
                        'Stack · ${s.layers.length} '
                        '${s.layers.length == 1 ? 'layer' : 'layers'}',
                      ),
                      subtitle: Text(
                        _when(s.created) +
                            (store.stackEdited(s) ? ' · Edited' : ''),
                      ),
                      onTap: () => _push(StackScreen(store: store, stack: s)),
                    ),
                  _header('Takes', theme),
                ],
                for (final take in _takes) _takeTile(take, store, theme),
              ],
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
