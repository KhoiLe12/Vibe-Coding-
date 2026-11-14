// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Tempo controls shared by every screen (M5b, wiki/features/beat-grid.md):
// a sheet to set BPM (± buttons, slider, typing, tap tempo), time signature,
// and where relevant count-in and click; and a beat light that shows the
// beat (the click is only audible during a count-in, d017).

import 'package:flutter/material.dart';

import '../tempo/grid.dart';

/// Time signatures offered: beats per bar over the beat unit.
const signatures = <(int, int)>[
  (2, 4),
  (3, 4),
  (4, 4),
  (5, 4),
  (6, 8),
  (7, 8),
  (12, 8),
];

class TempoChoice {
  const TempoChoice({
    required this.grid,
    this.countInBars = 1,
    this.clickWhileRecording = false,
    this.downbeatAtPlayhead = false,
  });

  /// Null: tempo removed.
  final Grid? grid;
  final int countInBars;
  final bool clickWhileRecording;

  /// The editor's "Downbeat at playhead".
  final bool downbeatAtPlayhead;
}

/// Opens the tempo sheet. Returns null if dismissed.
Future<TempoChoice?> showTempoSheet(
  BuildContext context, {
  required Grid initial,
  String title = 'Tempo',
  String? subtitle,
  bool countIn = false,
  int countInBars = 1,
  bool click = false,
  bool clickWhileRecording = false,
  bool downbeatAtPlayhead = false,
  bool removable = false,
  Future<DetectedTempo?> Function(Grid current)? onDetect,
}) {
  var grid = initial;
  var detecting = false;
  String? detected;
  var bars = countInBars;
  var clickOn = clickWhileRecording;
  final tap = TapTempo();

  return showModalBottomSheet<TempoChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheet) {
        final theme = Theme.of(context);
        void setBpm(double v) => setSheet(
          () => grid = grid.copyWith(
            bpm:
                (v * 10).round().clamp(Grid.minBpm * 10, Grid.maxBpm * 10) / 10,
          ),
        );
        TempoChoice result({bool atPlayhead = false}) => TempoChoice(
          grid: grid,
          countInBars: bars,
          clickWhileRecording: clickOn,
          downbeatAtPlayhead: atPlayhead,
        );

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                if (subtitle != null)
                  Text(subtitle, style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                Row(
                  children: [
                    IconButton.outlined(
                      key: const Key('bpm-down'),
                      onPressed: () => setBpm(grid.bpm.roundToDouble() - 1),
                      icon: const Icon(Icons.remove),
                    ),
                    Expanded(
                      child: InkWell(
                        key: const Key('bpm-value'),
                        onTap: () async {
                          final v = await _typeBpm(context, grid.bpm);
                          if (v != null) setBpm(v);
                        },
                        child: Column(
                          children: [
                            Text(
                              grid.bpmLabel,
                              style: theme.textTheme.displaySmall,
                            ),
                            Text('BPM', style: theme.textTheme.bodySmall),
                          ],
                        ),
                      ),
                    ),
                    IconButton.outlined(
                      key: const Key('bpm-up'),
                      onPressed: () => setBpm(grid.bpm.roundToDouble() + 1),
                      icon: const Icon(Icons.add),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      height: 56,
                      child: FilledButton.tonal(
                        key: const Key('tap-tempo'),
                        onPressed: () {
                          final bpm = tap.tap();
                          if (bpm != null) setBpm(bpm);
                        },
                        child: const Text('Tap'),
                      ),
                    ),
                  ],
                ),
                if (onDetect != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        OutlinedButton.icon(
                          key: const Key('detect-tempo'),
                          onPressed: detecting
                              ? null
                              : () async {
                                  setSheet(() {
                                    detecting = true;
                                    detected = null;
                                  });
                                  DetectedTempo? r;
                                  try {
                                    r = await onDetect(grid);
                                  } on Object {
                                    r = null;
                                  }
                                  if (!context.mounted) return;
                                  setSheet(() {
                                    detecting = false;
                                    if (r == null) {
                                      detected = 'No steady beat found.';
                                    } else {
                                      grid = r.grid;
                                      detected = r.confidence >= 0.5
                                          ? 'Detected ${grid.bpmLabel} BPM.'
                                          : 'Detected ${grid.bpmLabel} BPM '
                                                '(not sure: check it by ear).';
                                    }
                                  });
                                },
                          icon: detecting
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.graphic_eq),
                          label: const Text('Detect'),
                        ),
                        const SizedBox(width: 8),
                        // Detectors (and people) often hear half or double
                        // time.
                        TextButton(
                          key: const Key('bpm-half'),
                          onPressed: grid.bpm / 2 >= Grid.minBpm
                              ? () => setBpm(grid.bpm / 2)
                              : null,
                          child: const Text('½×'),
                        ),
                        TextButton(
                          key: const Key('bpm-double'),
                          onPressed: grid.bpm * 2 <= Grid.maxBpm
                              ? () => setBpm(grid.bpm * 2)
                              : null,
                          child: const Text('2×'),
                        ),
                        if (detected != null)
                          Expanded(
                            child: Text(
                              detected!,
                              key: const Key('detect-result'),
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ),
                  ),
                Slider(
                  key: const Key('bpm-slider'),
                  value: grid.bpm.clamp(40, 240).toDouble(),
                  min: 40,
                  max: 240,
                  onChanged: (v) => setBpm(v.roundToDouble()),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final (n, u) in signatures)
                      ChoiceChip(
                        key: Key('sig-$n-$u'),
                        label: Text('$n/$u'),
                        selected: grid.beatsPerBar == n && grid.beatUnit == u,
                        onSelected: (_) => setSheet(
                          () =>
                              grid = grid.copyWith(beatsPerBar: n, beatUnit: u),
                        ),
                      ),
                  ],
                ),
                if (countIn) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Expanded(child: Text('Count-in')),
                      SegmentedButton<int>(
                        key: const Key('count-in'),
                        segments: const [
                          ButtonSegment(value: 0, label: Text('Off')),
                          ButtonSegment(value: 1, label: Text('1 bar')),
                          ButtonSegment(value: 2, label: Text('2 bars')),
                        ],
                        selected: {bars},
                        onSelectionChanged: (s) =>
                            setSheet(() => bars = s.first),
                      ),
                    ],
                  ),
                ],
                if (click)
                  SwitchListTile(
                    key: const Key('click-while-recording'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Click while recording'),
                    subtitle: const Text(
                      'For headphones. Through the speaker the click '
                      'is recorded too.',
                    ),
                    value: clickOn,
                    onChanged: (v) => setSheet(() => clickOn = v),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (removable)
                      TextButton(
                        key: const Key('tempo-remove'),
                        onPressed: () => Navigator.pop(
                          context,
                          TempoChoice(
                            grid: null,
                            countInBars: bars,
                            clickWhileRecording: clickOn,
                          ),
                        ),
                        child: const Text('Remove tempo'),
                      ),
                    const Spacer(),
                    if (downbeatAtPlayhead)
                      TextButton(
                        key: const Key('downbeat-here'),
                        onPressed: () =>
                            Navigator.pop(context, result(atPlayhead: true)),
                        child: const Text('Downbeat at playhead'),
                      ),
                    FilledButton(
                      key: const Key('tempo-done'),
                      onPressed: () => Navigator.pop(context, result()),
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

Future<double?> _typeBpm(BuildContext context, double bpm) {
  final c = TextEditingController(text: Grid(bpm: bpm).bpmLabel);
  return showDialog<double>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('BPM'),
      content: TextField(
        key: const Key('bpm-field'),
        controller: c,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onSubmitted: (v) => Navigator.pop(context, double.tryParse(v)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, double.tryParse(c.text)),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// The beat, shown: one dot per beat of the bar, the current one lit (the
/// bar's first beat larger); during a count-in, the beats left as a number.
class BeatLight extends StatelessWidget {
  const BeatLight({
    super.key,
    required this.beat,
    required this.beatsPerBar,
    this.countingIn = false,
  });

  /// Musical beat being heard (fractional; negative during a count-in), or
  /// null when stopped.
  final double? beat;
  final int beatsPerBar;
  final bool countingIn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final b = beat;
    final index = b?.floor();
    final inBar = index == null
        ? -1
        : ((index % beatsPerBar) + beatsPerBar) % beatsPerBar;
    // Lit for the first part of each beat, like a flash.
    final flash = b != null && b - b.floorToDouble() < 0.35;
    final dots = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < beatsPerBar; i++)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == 0 ? 16 : 12,
            height: i == 0 ? 16 : 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i == inBar
                  ? (flash
                        ? (i == 0 ? scheme.error : scheme.primary)
                        : scheme.primary.withValues(alpha: 0.4))
                  : scheme.outlineVariant,
            ),
          ),
      ],
    );
    if (!countingIn || b == null || b >= 0) {
      return Semantics(label: 'Beat ${inBar + 1}', child: dots);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${-index!}',
          key: const Key('count-in-number'),
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(color: scheme.error),
        ),
        const SizedBox(width: 12),
        dots,
      ],
    );
  }
}
