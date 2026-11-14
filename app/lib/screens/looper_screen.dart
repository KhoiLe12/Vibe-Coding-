// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Loop pedal, part one (wiki/features/loop-pedal.md, wiki/decisions/
// d014-looper-m5a.md): one big button (record → close loop → overdub on/off),
// play/stop, undo/redo layer, clear, per-layer volume/mute/solo, calibration
// per route, bounce to a new take. The loop itself runs in the C++ audio
// callback; this screen only sends commands and shows state.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocket_audio/pocket_audio.dart';

import '../audio/audio_control.dart';
import '../audio/calibration.dart';
import '../takes/take_store.dart';
import '../widgets/waveform.dart';

class LooperScreen extends StatefulWidget {
  const LooperScreen({super.key, required this.store});

  final TakeStore store;

  @override
  State<LooperScreen> createState() => _LooperScreenState();
}

class _Layer {
  double volume = 1;
  bool muted = false;
  bool solo = false;
}

class _LooperScreenState extends State<LooperScreen> {
  // Remembered while the app runs. 0 dB: the loop pedal runs in iOS's
  // default mode, which keeps the speaker's normal loudness (the +12 dB
  // boosts were a wrong fix for measurement mode's quiet speaker, d014).
  static double _micGainDb = 0;
  static double _loopVolumeDb = 0;

  static double _db(double db) => math.pow(10, db / 20).toDouble();

  /// Calibration key: the round trip differs per route and per iOS mode.
  static String _key(String route) => '$route/default-mode';

  late final Calibration _calibration = Calibration(
    widget.store.calibrationFile,
  );
  Timer? _ticker;
  String? _error;
  bool _ready = false;
  bool _calibrating = false;
  String _route = 'default';
  int? _latency; // frames
  double _meter = 0;
  double _outMeter = 0;
  bool _busy = false;

  LooperState _state = LooperState.idle;
  int _position = 0, _length = 0, _layers = 0, _redoable = 0;
  final List<_Layer> _layerSettings = [];

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    Looper.disable();
    PocketAudio.stopLatencyProbe();
    AudioControl.release();
    super.dispose();
  }

  Future<void> _open() async {
    final mic = await AudioControl.ensureMic();
    if (!mounted) return;
    if (mic != MicPermission.granted) {
      setState(
        () => _error =
            'The loop pedal needs the microphone. Allow '
            'it in Settings › Pocket Studio › Microphone.',
      );
      return;
    }
    try {
      // Default mode, not measurement: keeps the speaker's normal loudness.
      AudioControl.useInput(raw: false);
    } on PocketAudioException catch (e) {
      setState(() => _error = 'Could not open audio (${e.message}).');
      return;
    }
    Looper.enable();
    Looper.inputGain = _db(_micGainDb);
    Looper.outputGain = _db(_loopVolumeDb);
    Looper.resetClip();
    _route = PocketAudio.outputRoute;
    _latency = _calibration.framesFor(_key(_route));
    if (_latency != null) Looper.latencyFrames = _latency!;
    _ticker = Timer.periodic(const Duration(milliseconds: 33), (_) => _tick());
    setState(() => _ready = true);
    if (_latency == null) await _calibrate();
  }

  Future<void> _calibrate() async {
    if (_state != LooperState.idle) return;
    setState(() {
      _calibrating = true;
      _error = null;
    });
    final frames = await Calibration.measure();
    if (!mounted) return;
    setState(() {
      _calibrating = false;
      if (frames == null) {
        _error =
            'Calibration could not hear its chirps. Turn the volume up, '
            'keep the room quiet, and try again.';
      } else {
        _latency = frames;
        _calibration.save(_key(_route), frames);
        Looper.latencyFrames = frames;
      }
    });
  }

  void _tick() {
    final route = PocketAudio.outputRoute;
    if (route != _route) {
      // Headphones plugged in / Bluetooth connected: different round trip.
      _route = route;
      _latency = _calibration.framesFor(_key(route));
      if (_latency != null) Looper.latencyFrames = _latency!;
    }
    final level = Looper.takeInputPeak();
    final layers = Looper.layers;
    while (_layerSettings.length < layers + Looper.redoable) {
      _layerSettings.add(_Layer());
    }
    setState(() {
      _meter = math.max(level, _meter * 0.85);
      _outMeter = math.max(Looper.takeOutputPeak(), _outMeter * 0.85);
      _state = Looper.state;
      _position = Looper.position;
      _length = Looper.length;
      _layers = layers;
      _redoable = Looper.redoable;
    });
    if (_state == LooperState.idle && _layerSettings.isNotEmpty) {
      _layerSettings.clear();
    }
  }

  void _applyGains() {
    final anySolo = _layerSettings.take(_layers).any((l) => l.solo);
    for (var i = 0; i < _layerSettings.length; i++) {
      final l = _layerSettings[i];
      final audible = !l.muted && (!anySolo || l.solo);
      Looper.setLayerGain(i, audible ? l.volume : 0);
    }
  }

  Future<void> _deleteLayer(int i) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete layer $i?'),
        content: const Text('This can\'t be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    Looper.deleteLayer(i);
    // Layers above move down one index, in the engine and here.
    setState(() {
      if (i < _layerSettings.length) _layerSettings.removeAt(i);
    });
    _applyGains();
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear the loop?'),
        content: const Text('All layers will be discarded.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) {
      Looper.clear();
      _layerSettings.clear();
    }
  }

  Future<void> _bounce() async {
    final passes = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Bounce to a new take'),
        children: [
          for (final n in [1, 2, 4, 8])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, n),
              child: Text(
                '$n ${n == 1 ? 'pass' : 'passes'} '
                '(${formatDuration(Duration(milliseconds: _length * n * 1000 ~/ sampleRate))})',
              ),
            ),
        ],
      ),
    );
    if (passes == null || !mounted) return;
    setState(() => _busy = true);
    if (_recordingLayer) Looper.press(); // cancel the layer in progress
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final t = widget.store.newTake();
    try {
      Looper.bounce(t.wav, passes: passes);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bounced to a new take in your list.')),
      );
    } on PocketAudioException catch (e) {
      setState(() => _error = 'Bounce failed (${e.message}).');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmLeave() async {
    if (_state == LooperState.idle) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave the loop pedal?'),
        content: const Text(
          'The loop is not kept. Bounce it first to keep it as a take.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  bool get _recordingLayer =>
      _state == LooperState.overdubbing || _state == LooperState.armed;

  ({String label, IconData icon, Color color}) _mainButton(ColorScheme s) =>
      switch (_state) {
        LooperState.idle => (
          label: 'Record',
          icon: Icons.fiber_manual_record,
          color: s.error,
        ),
        LooperState.recording => (
          label: 'Close loop',
          icon: Icons.loop,
          color: s.error,
        ),
        LooperState.closing => (
          label: 'Closing…',
          icon: Icons.loop,
          color: s.outline,
        ),
        LooperState.playing || LooperState.stopped => (
          label: 'Overdub',
          icon: Icons.layers,
          color: s.tertiary,
        ),
        LooperState.overdubbing || LooperState.armed => (
          label: 'Recording layer · cancel',
          icon: Icons.layers_clear,
          color: s.error,
        ),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final main = _mainButton(scheme);
    final hasLoop = _length > 0;
    final speaker = _route == 'Speaker';
    final bluetooth = _route.startsWith('Bluetooth');

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Loop pedal'),
          actions: [
            IconButton(
              key: const Key('looper-undo'),
              tooltip: 'Undo layer',
              onPressed: _layers > 1 && !_recordingLayer ? Looper.undo : null,
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              key: const Key('looper-redo'),
              tooltip: 'Redo layer',
              onPressed: _redoable > 0 && !_recordingLayer ? Looper.redo : null,
              icon: const Icon(Icons.redo),
            ),
            PopupMenuButton<String>(
              onSelected: (v) => switch (v) {
                'calibrate' => _calibrate(),
                'bounce' => _bounce(),
                _ => _clear(),
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'bounce',
                  enabled: hasLoop && !_busy,
                  child: const Text('Bounce to new take'),
                ),
                PopupMenuItem(
                  value: 'calibrate',
                  enabled: _state == LooperState.idle && !_calibrating,
                  child: const Text('Calibrate latency'),
                ),
                PopupMenuItem(
                  value: 'clear',
                  enabled: hasLoop,
                  child: const Text('Clear loop'),
                ),
              ],
            ),
          ],
        ),
        body: SafeArea(
          child: !_ready && _error == null
              ? const Center(child: CircularProgressIndicator())
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_error != null)
                        _Banner(text: _error!, color: scheme.errorContainer),
                      if (_calibrating)
                        _Banner(
                          text:
                              'Calibrating: listen for chirps and keep '
                              'quiet for a few seconds…',
                          color: scheme.secondaryContainer,
                        )
                      else if (speaker && _ready)
                        _Banner(
                          text:
                              'Through the speaker, the mic also records '
                              'the loop into each new layer. Headphones '
                              'avoid this.',
                          color: scheme.surfaceContainerHighest,
                        )
                      else if (bluetooth)
                        _Banner(
                          text:
                              'Bluetooth adds a long, changing delay. '
                              'Overdubs may not line up.',
                          color: scheme.errorContainer,
                        ),
                      if (Looper.starved)
                        _Banner(
                          text: 'Overdub could not start yet — try again.',
                          color: scheme.errorContainer,
                        ),
                      const SizedBox(height: 8),
                      _LoopProgress(
                        state: _state,
                        position: _position,
                        length: _length,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const SizedBox(width: 44, child: Text('Mic')),
                          Expanded(
                            child: LevelMeter(
                              peak: _meter,
                              clipped: Looper.clipped,
                              onResetClip: Looper.resetClip,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const SizedBox(width: 44, child: Text('Loop')),
                          Expanded(
                            child: LevelMeter(
                              key: const Key('loop-meter'),
                              peak: _outMeter,
                              clipped: false,
                              onResetClip: () {},
                            ),
                          ),
                        ],
                      ),
                      _gainSlider(
                        key: const Key('mic-gain'),
                        label: 'Mic gain',
                        value: _micGainDb,
                        min: -12,
                        max: 30,
                        onChanged: (v) {
                          setState(() => _micGainDb = v);
                          Looper.inputGain = _db(v);
                        },
                      ),
                      _gainSlider(
                        key: const Key('loop-volume'),
                        label: 'Loop volume',
                        value: _loopVolumeDb,
                        min: -12,
                        max: 24,
                        onChanged: (v) {
                          setState(() => _loopVolumeDb = v);
                          Looper.outputGain = _db(v);
                        },
                      ),
                      Text(
                        _latency == null
                            ? 'Not calibrated for this route'
                            : 'Round trip ${(_latency! / 48).toStringAsFixed(1)} ms '
                                  '($_route) — overdubs are shifted back by it',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: _layers == 0
                            ? Center(
                                child: Text(
                                  'Tap Record, play, and tap Close loop.\n'
                                  'Then tap Overdub: the loop restarts and '
                                  'records one full pass as a new layer.',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyLarge,
                                ),
                              )
                            : ListView.builder(
                                itemCount: _layers,
                                itemBuilder: (context, i) =>
                                    _layerRow(i, theme),
                              ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          IconButton.filledTonal(
                            key: const Key('looper-playstop'),
                            iconSize: 32,
                            tooltip: _state == LooperState.stopped
                                ? 'Play'
                                : 'Stop',
                            onPressed: hasLoop
                                ? (_state == LooperState.stopped
                                      ? Looper.play
                                      : Looper.stop)
                                : null,
                            icon: Icon(
                              _state == LooperState.stopped
                                  ? Icons.play_arrow
                                  : Icons.stop,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: SizedBox(
                              height: 96,
                              child: FilledButton.icon(
                                key: const Key('looper-main'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: main.color,
                                  foregroundColor: scheme.onError,
                                  textStyle: theme.textTheme.titleLarge,
                                ),
                                onPressed:
                                    _ready &&
                                        !_calibrating &&
                                        !_busy &&
                                        _state != LooperState.closing
                                    ? Looper.press
                                    : null,
                                icon: Icon(main.icon, size: 36),
                                label: Text(main.label),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _gainSlider({
    required Key key,
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    final text = '${value >= 0 ? '+' : ''}${value.round()} dB';
    return Row(
      children: [
        SizedBox(width: 92, child: Text(label)),
        Expanded(
          child: Slider(
            key: key,
            value: value,
            min: min,
            max: max,
            divisions: (max - min).round(),
            label: text,
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 52, child: Text(text, textAlign: TextAlign.end)),
      ],
    );
  }

  Widget _layerRow(int i, ThemeData theme) {
    final l = _layerSettings[i];
    return Row(
      children: [
        SizedBox(width: 72, child: Text(i == 0 ? 'First take' : 'Layer $i')),
        Expanded(
          child: Slider(
            value: l.volume,
            max: 1.5,
            onChanged: (v) {
              setState(() => l.volume = v);
              _applyGains();
            },
          ),
        ),
        IconButton(
          tooltip: l.muted ? 'Unmute' : 'Mute',
          isSelected: l.muted,
          onPressed: () {
            setState(() => l.muted = !l.muted);
            _applyGains();
          },
          icon: const Icon(Icons.volume_up),
          selectedIcon: const Icon(Icons.volume_off),
        ),
        IconButton(
          tooltip: l.solo ? 'Unsolo' : 'Solo',
          isSelected: l.solo,
          onPressed: () {
            setState(() => l.solo = !l.solo);
            _applyGains();
          },
          icon: const Icon(Icons.headphones_outlined),
          selectedIcon: const Icon(Icons.headphones),
        ),
        // The first take sets the loop, so it can only be muted.
        IconButton(
          key: Key('delete-layer-$i'),
          tooltip: i == 0 ? 'The first take can only be muted' : 'Delete layer',
          onPressed: i == 0 || _recordingLayer ? null : () => _deleteLayer(i),
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(text),
  );
}

/// Loop position as a bar, or the growing first take while recording.
class _LoopProgress extends StatelessWidget {
  const _LoopProgress({
    required this.state,
    required this.position,
    required this.length,
  });

  final LooperState state;
  final int position, length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recording = state == LooperState.recording;
    final secs = (recording ? position : length) / sampleRate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          recording
              ? 'Recording first take: ${secs.toStringAsFixed(1)} s'
              : length == 0
              ? 'No loop'
              : 'Loop ${secs.toStringAsFixed(2)} s'
                    '${state == LooperState.overdubbing || state == LooperState.armed ? ' — recording a layer' : ''}'
                    '${state == LooperState.stopped ? ' — stopped' : ''}',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(
          minHeight: 12,
          borderRadius: BorderRadius.circular(6),
          value: recording
              ? null
              : length == 0
              ? 0
              : position / length,
          color: state == LooperState.overdubbing
              ? theme.colorScheme.error
              : null,
        ),
      ],
    );
  }
}
