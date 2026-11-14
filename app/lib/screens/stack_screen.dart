// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// A stack of layers (M6, wiki/features/layers.md, wiki/decisions/
// d015-layers.md): add existing takes or record new ones on top while the
// stack plays, slide layers in time, volume/mute/solo/delete, undo/redo,
// bounce to a take. Each layer plays its take with the take's own edits (and
// its pitch/tempo render, if one has been made).

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocket_audio/pocket_audio.dart';

import '../audio/audio_control.dart';
import '../audio/calibration.dart';
import '../edit/edit_list.dart';
import '../edit/render_cache.dart';
import '../stack/bounce.dart';
import '../stack/stack.dart';
import '../takes/take_store.dart';
import '../widgets/waveform.dart';
import 'take_screen.dart';

class StackScreen extends StatefulWidget {
  const StackScreen({super.key, required this.store, required this.stack});

  final TakeStore store;
  final LayerStack stack;

  @override
  State<StackScreen> createState() => _StackScreenState();
}

/// What the screen knows about one layer's audio.
class _LayerAudio {
  _LayerAudio(this.take, this.track, this.length, this.peaks, this.unrendered)
    : onset = peaks == null ? 0 : soundStartFrame(peaks, length);

  final Take? take; // null: the take was deleted
  final StackTrack? track;
  final int length; // as it plays (after tempo)
  final Peaks? peaks; // timeline peaks in edit frames
  final bool unrendered; // pitch/tempo set but no render yet

  /// Where the sound starts inside the layer (frames as it plays): the first
  /// moment the waveform reaches 20 % of its loudest point. Recordings often
  /// begin with a little silence; this is what lines up musically.
  final int onset;
}

class _StackScreenState extends State<StackScreen> {
  late History<LayerStack> _history;
  LayerStack get _stack => _history.current;
  final Map<String, _LayerAudio> _audio = {};
  Timer? _ticker;
  int _position = 0, _length = 0;
  bool _playing = false;
  String? _message;

  // Recording a layer.
  bool _recording = false;
  ({String id, String wav, String peaks})? _newTake;
  int _recordedFrames = 0;

  /// Magnetic snapping on/off (remembered while the app runs).
  static bool _snapOn = true;

  // Sliding a layer: index, raw finger offset, and the (snapped) offset shown.
  int? _dragging;
  double _dragRaw = 0;
  double _dragOffset = 0;
  bool _snapped = false;

  // The lanes' scale (frames across the width). It only grows during a
  // session: recomputing it from the stack length made every waveform jump
  // when a slide changed that length (human, 2026-11-14).
  double _viewFrames = 0;

  late final Calibration _calibration = Calibration(
    widget.store.calibrationFile,
  );

  @override
  void initState() {
    super.initState();
    _history = History(widget.stack);
    PocketAudio.openStack();
    AudioControl.ensureOutput(); // play retries if iOS refuses right now
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (!_recording) AudioControl.ensureOutput();
      },
    );
    _rebuild();
    _ticker = Timer.periodic(const Duration(milliseconds: 33), (_) => _tick());
  }

  late final AppLifecycleListener _lifecycle;

  @override
  void dispose() {
    _lifecycle.dispose();
    _ticker?.cancel();
    if (PocketAudio.isRecording) PocketAudio.endRecording();
    PocketAudio.closeTake();
    AudioControl.release();
    super.dispose();
  }

  // ---- audio ----

  Future<_LayerAudio> _resolve(String takeId, Map<String, Take> takes) async {
    final take = takes[takeId];
    if (take == null) return _LayerAudio(null, null, 0, null, false);
    final store = widget.store;
    final edits = store.loadEdits(take.id, take.frames);
    var path = take.wav.path;
    var clips = [
      for (final c in edits.clips) (start: c.start, end: c.end, gain: c.gain),
    ];
    var unrendered = false;
    if (!edits.tune.isIdentity) {
      final need = RenderCache.neededRange(edits, take.frames);
      final r = store.renders.find(take.id, edits.tune, need.start, need.end);
      if (r != null) {
        path = r.path;
        clips = r.clipsFor(edits);
      } else {
        unrendered = true;
      }
    }
    final length = clips.fold<int>(0, (s, c) => s + c.end - c.start);
    Peaks? peaks;
    try {
      peaks = timelinePeaks(await store.loadPeaks(take), edits);
    } on Object {
      peaks = null;
    }
    return _LayerAudio(
      take,
      StackTrack(path, 0, clips),
      length,
      peaks,
      unrendered,
    );
  }

  /// Loads any layer audio not known yet, then hands the stack to the engine.
  Future<void> _rebuild() async {
    final takes = {for (final t in widget.store.list()) t.id: t};
    for (final l in _stack.layers) {
      if (!_audio.containsKey(l.takeId)) {
        _audio[l.takeId] = await _resolve(l.takeId, takes);
      }
    }
    if (!mounted) return;
    _push();
  }

  void _push() {
    final tracks = <StackTrack>[];
    final gains = _stack.gains;
    final index = <int>[]; // stack layer → engine track
    for (var i = 0; i < _stack.layers.length; i++) {
      final l = _stack.layers[i];
      final a = _audio[l.takeId];
      if (a?.track == null) continue;
      index.add(i);
      tracks.add(StackTrack(a!.track!.path, l.offset, a.track!.clips));
    }
    try {
      _length = PocketAudio.setStack(tracks);
      for (var k = 0; k < index.length; k++) {
        PocketAudio.setTrackGain(k, gains[index[k]]);
      }
    } on PocketAudioException catch (e) {
      _message = 'Could not play a layer (${e.message}).';
    }
    final missing = _stack.layers.where((l) => _audio[l.takeId]?.take == null);
    final unrendered = _stack.layers.where(
      (l) => _audio[l.takeId]?.unrendered ?? false,
    );
    setState(() {
      _message ??= missing.isNotEmpty
          ? 'A layer\'s take was deleted.'
          : unrendered.isNotEmpty
          ? 'A layer has pitch/tempo that hasn\'t been rendered yet; it '
                'plays unchanged. Open that take once to render it.'
          : null;
    });
  }

  /// Records a change (undoable), saves it and updates the engine.
  void _apply(String label, LayerStack next, {bool coalesce = false}) {
    if (!_history.push(label, next, coalesce: coalesce)) return;
    widget.store.saveStack(next);
    _rebuild();
  }

  void _undo() {
    if (!_history.canUndo) return;
    widget.store.saveStack(_history.undo());
    _rebuild();
  }

  void _redo() {
    if (!_history.canRedo) return;
    widget.store.saveStack(_history.redo());
    _rebuild();
  }

  void _tick() {
    if (_recording) _recordedFrames = PocketAudio.framesWritten;
    final playing = PocketAudio.isPlaying;
    final pos = PocketAudio.playbackPosition;
    if (playing != _playing || pos != _position || _recording) {
      setState(() {
        _playing = playing;
        _position = pos;
      });
    }
  }

  Future<void> _toggle() async {
    if (PocketAudio.isPlaying) {
      PocketAudio.playing = false;
      return;
    }
    if (!await AudioControl.ensureOutput()) {
      if (mounted) {
        setState(
          () => _message =
              'iOS did not let the app start audio. '
              'Try again in a moment.',
        );
      }
      return;
    }
    if (PocketAudio.playbackFinished) PocketAudio.seek(0);
    PocketAudio.playing = true;
  }

  // ---- layers ----

  Future<void> _addTake() async {
    final takes = widget.store.list();
    if (takes.isEmpty) {
      setState(() => _message = 'No takes yet: record one first.');
      return;
    }
    final picked = await showModalBottomSheet<Take>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final t in takes)
              ListTile(
                leading: const Icon(Icons.graphic_eq),
                title: Text(takeTitle(t)),
                trailing: Text(formatDuration(t.duration)),
                onTap: () => Navigator.pop(context, t),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (_stack.full) {
      setState(
        () => _message = 'A stack holds up to ${LayerStack.maxLayers} layers.',
      );
      return;
    }
    _apply('Add layer', _stack.add(Layer(picked.id)));
  }

  Future<void> _recordLayer() async {
    if (_stack.full) {
      setState(
        () => _message = 'A stack holds up to ${LayerStack.maxLayers} layers.',
      );
      return;
    }
    final mic = await AudioControl.ensureMic();
    if (!mounted) return;
    if (mic != MicPermission.granted) {
      setState(
        () => _message =
            'Recording needs the microphone. Allow it in '
            'Settings › Pocket Studio › Microphone.',
      );
      return;
    }
    // Same loud iOS mode as the loop pedal, so the stack is heard at normal
    // volume while you play (d014); calibration is shared with it.
    try {
      AudioControl.useInput(raw: false);
    } on PocketAudioException catch (e) {
      setState(
        () => _message = 'Could not open the microphone (${e.message}).',
      );
      return;
    }
    final key = '${PocketAudio.outputRoute}/default-mode';
    var latency = _calibration.framesFor(key);
    if (latency == null) {
      setState(() => _message = 'Calibrating first: listen for chirps…');
      latency = await Calibration.measure();
      if (!mounted) return;
      if (latency == null) {
        setState(
          () => _message =
              'Calibration could not hear its chirps. '
              'Turn the volume up and try again.',
        );
        AudioControl.useOutput();
        return;
      }
      _calibration.save(key, latency);
    }
    _latency = latency;
    final t = widget.store.newTake();
    try {
      PocketAudio.beginRecording(t.wav, sampleRate: sampleRate);
    } on PocketAudioException catch (e) {
      setState(() => _message = 'Could not start recording (${e.message}).');
      AudioControl.useOutput();
      return;
    }
    PocketAudio.playing = true; // play the stack while recording
    setState(() {
      _newTake = t;
      _recording = true;
      _recordedFrames = 0;
      _message = null;
    });
  }

  int _latency = 0;

  Future<void> _stopRecording() async {
    final t = _newTake!;
    PocketAudio.playing = false;
    final stamp = PocketAudio.recorderStartStamp;
    PocketAudio.endRecording(peaksPath: t.peaks);
    AudioControl.useOutput();
    setState(() {
      _recording = false;
      _newTake = null;
    });
    final take = widget.store.takeById(t.id);
    if (take == null) {
      setState(() => _message = 'Nothing was recorded.');
      return;
    }
    // Where the first recorded sound belongs: the stack position playing
    // when it reached the mic, minus the calibrated round trip.
    final offset = stamp >= 0 ? math.max(0, stamp - _latency) : 0;
    _apply('Record layer', _stack.add(Layer(take.id, offset: offset)));
  }

  /// Magnetic snapping while sliding layer [i]. Two anchors move with the
  /// finger — the layer's sound start (preferred) and its file start — and
  /// within a finger's width either snaps to another layer's sound start,
  /// start or end, the playhead, or the 1-second grid.
  ({double offset, bool snapped}) _snap(int i, double raw, double perPx) {
    if (!_snapOn) return (offset: raw, snapped: false);
    final tol = 14 * perPx;
    final onset = (_audio[_stack.layers[i].takeId]?.onset ?? 0).toDouble();
    final targets = <double>[0, _position.toDouble()];
    for (var k = 0; k < _stack.layers.length; k++) {
      if (k == i) continue;
      final a = _audio[_stack.layers[k].takeId];
      final o = _stack.layers[k].offset.toDouble();
      targets
        ..add(o)
        ..add(o + (a?.onset ?? 0))
        ..add(o + (a?.length ?? 0));
    }
    double? shift;
    void consider(double anchor, Iterable<double> ts, {double bias = 1}) {
      for (final t in ts) {
        final d = t - anchor;
        if (d.abs() <= tol &&
            (shift == null || d.abs() * bias < shift!.abs())) {
          shift = d;
        }
      }
    }

    double gridNear(double x) => (x / sampleRate).roundToDouble() * sampleRate;
    // Sound start first (slightly preferred), then the file start.
    consider(raw + onset, [...targets, gridNear(raw + onset)], bias: 0.8);
    consider(raw, [...targets, gridNear(raw)]);
    return shift == null
        ? (offset: raw, snapped: false)
        : (offset: raw + shift!, snapped: true);
  }

  /// Opens a layer's take in the normal editor (chop, transpose, tempo…);
  /// the stack plays the changes when you come back.
  Future<void> _editLayer(int i) async {
    final take = _audio[_stack.layers[i].takeId]?.take;
    if (take == null || _recording) return;
    PocketAudio.playing = false;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TakeScreen(store: widget.store, take: take),
      ),
    );
    if (!mounted) return;
    // The editor closed the player and released the engine: reopen both.
    AudioControl.useOutput();
    PocketAudio.openStack();
    final fresh = widget.store.takeById(take.id);
    _audio.remove(take.id);
    if (fresh == null) {
      setState(() => _message = 'That take was deleted.');
    }
    await _rebuild();
  }

  void _removeLayer(int i) => _apply('Remove layer', _stack.remove(i));

  void _setLayer(int i, Layer l, String label, {bool coalesce = false}) =>
      _apply(label, _stack.replace(i, l), coalesce: coalesce);

  Future<void> _bounce() async {
    final t = widget.store.newTake();
    setState(() => _message = 'Bouncing…');
    final path = t.wav;
    try {
      await bounceStackInBackground(path);
      if (!mounted) return;
      setState(() => _message = 'Bounced to a new take in your list.');
    } on Object catch (e) {
      if (mounted) setState(() => _message = 'Bounce failed ($e).');
    }
  }

  /// Chop/transpose/tempo on the combined stack: the current arrangement is
  /// mixed into one recording and opened in the take editor. The stack's
  /// edits are saved with the stack (by time on the stack).
  Future<void> _editWholeStack() async {
    PocketAudio.playing = false;
    final store = widget.store;
    final path = store.stackMixPath(_stack);
    try {
      if (!File(path).existsSync()) await bounceStackInBackground(path);
    } on Object catch (e) {
      setState(() => _message = 'Could not prepare the stack ($e).');
      return;
    }
    if (!mounted) return;
    final mix = store.stackMixTake(_stack, path);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TakeScreen(store: store, take: mix),
      ),
    );
    if (!mounted) return;
    AudioControl.useOutput();
    PocketAudio.openStack();
    await _rebuild();
    setState(
      () => _message = store.stackEdited(_stack)
          ? 'The stack has edits: they apply in "Edit whole stack" and its '
                'bounce; here you arrange the layers.'
          : null,
    );
  }

  Future<void> _deleteStack() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this stack?'),
        content: const Text('The layers\' takes stay in your list.'),
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
    widget.store.deleteStack(_stack);
    Navigator.of(context).pop();
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // The view spans the stack plus room to slide a layer later.
    _viewFrames = math.max(
      _viewFrames,
      math.max(_length, sampleRate * 4) * 1.25,
    );
    final view = _viewFrames;
    return PopScope(
      canPop: !_recording,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            'Stack · ${_stack.layers.length} '
            '${_stack.layers.length == 1 ? 'layer' : 'layers'}',
          ),
          actions: [
            IconButton(
              key: const Key('snap'),
              tooltip: _snapOn ? 'Snapping on' : 'Snapping off',
              isSelected: _snapOn,
              onPressed: () => setState(() => _snapOn = !_snapOn),
              icon: const Icon(Icons.grid_off),
              selectedIcon: const Icon(Icons.grid_on),
            ),
            IconButton(
              tooltip: 'Undo',
              onPressed: _history.canUndo && !_recording ? _undo : null,
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              tooltip: 'Redo',
              onPressed: _history.canRedo && !_recording ? _redo : null,
              icon: const Icon(Icons.redo),
            ),
            PopupMenuButton<String>(
              enabled: !_recording,
              onSelected: (v) => switch (v) {
                'edit' => _editWholeStack(),
                'bounce' => _bounce(),
                _ => _deleteStack(),
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'edit',
                  enabled: _length > 0,
                  child: const Text('Edit whole stack'),
                ),
                PopupMenuItem(
                  value: 'bounce',
                  enabled: _length > 0,
                  child: const Text('Bounce to new take'),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete stack'),
                ),
              ],
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_message != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(_message!),
                  ),
                _seekBar(view, scheme),
                const SizedBox(height: 8),
                Expanded(
                  child: _stack.layers.isEmpty
                      ? Center(
                          child: Text(
                            'Add a take, or record a layer.',
                            style: theme.textTheme.bodyLarge,
                          ),
                        )
                      : ListView.builder(
                          itemCount: _stack.layers.length,
                          itemBuilder: (context, i) => _lane(i, view, theme),
                        ),
                ),
                Text(
                  _recording
                      ? 'Recording layer · ${formatDuration(Duration(milliseconds: _recordedFrames * 1000 ~/ sampleRate))}'
                      : '${formatDuration(Duration(milliseconds: _position * 1000 ~/ sampleRate))}'
                            ' / ${formatDuration(Duration(milliseconds: _length * 1000 ~/ sampleRate))}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: _recording ? scheme.error : null,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('add-take'),
                        onPressed: _recording ? null : _addTake,
                        icon: const Icon(Icons.add),
                        label: const Text('Add take'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox.square(
                      dimension: 72,
                      child: FilledButton(
                        key: const Key('stack-play'),
                        style: FilledButton.styleFrom(
                          shape: const CircleBorder(),
                        ),
                        onPressed: _recording || _length == 0 ? null : _toggle,
                        child: Icon(
                          _playing ? Icons.pause : Icons.play_arrow,
                          size: 40,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        key: const Key('record-layer'),
                        style: FilledButton.styleFrom(
                          backgroundColor: scheme.error,
                          foregroundColor: scheme.onError,
                        ),
                        onPressed: _recording ? _stopRecording : _recordLayer,
                        icon: Icon(
                          _recording ? Icons.stop : Icons.fiber_manual_record,
                        ),
                        label: Text(_recording ? 'Stop' : 'Record layer'),
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

  Widget _seekBar(double view, ColorScheme scheme) => SizedBox(
    height: 28,
    child: LayoutBuilder(
      builder: (context, box) {
        void seek(double dx) {
          if (_recording) return;
          PocketAudio.seek(
            (dx / box.maxWidth * view).round().clamp(0, _length),
          );
        }

        return GestureDetector(
          key: const Key('stack-seek'),
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => seek(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => seek(d.localPosition.dx),
          child: CustomPaint(
            painter: _RulerPainter(
              length: _length / view,
              playhead: _position / view,
              color: scheme.primary,
              track: scheme.surfaceContainerHighest,
            ),
            child: const SizedBox.expand(),
          ),
        );
      },
    ),
  );

  Widget _lane(int i, double view, ThemeData theme) {
    final scheme = theme.colorScheme;
    final l = _stack.layers[i];
    final a = _audio[l.takeId];
    final name = a?.take == null
        ? 'Missing take'
        : 'Layer ${i + 1} · ${takeTitle(a!.take!)}';
    final offset = _dragging == i ? _dragOffset : l.offset.toDouble();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    key: Key('edit-layer-$i'),
                    onTap: a?.take == null ? null : () => _editLayer(i),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.edit, size: 16),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l.muted ? 'Unmute' : 'Mute',
                  isSelected: l.muted,
                  onPressed: _recording
                      ? null
                      : () => _setLayer(
                          i,
                          l.copyWith(muted: !l.muted),
                          l.muted ? 'Unmute' : 'Mute',
                        ),
                  icon: const Icon(Icons.volume_up),
                  selectedIcon: const Icon(Icons.volume_off),
                ),
                IconButton(
                  tooltip: l.solo ? 'Unsolo' : 'Solo',
                  isSelected: l.solo,
                  onPressed: _recording
                      ? null
                      : () => _setLayer(
                          i,
                          l.copyWith(solo: !l.solo),
                          l.solo ? 'Unsolo' : 'Solo',
                        ),
                  icon: const Icon(Icons.headphones_outlined),
                  selectedIcon: const Icon(Icons.headphones),
                ),
                IconButton(
                  key: Key('remove-layer-$i'),
                  tooltip: 'Remove layer (the take stays)',
                  onPressed: _recording ? null : () => _removeLayer(i),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            SizedBox(
              height: 48,
              child: LayoutBuilder(
                builder: (context, box) {
                  final w = box.maxWidth;
                  return GestureDetector(
                    key: Key('lane-$i'),
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: _recording
                        ? null
                        : (_) => setState(() {
                            _dragging = i;
                            _dragRaw = _dragOffset = l.offset.toDouble();
                            _snapped = false;
                          }),
                    onHorizontalDragUpdate: _recording
                        ? null
                        : (d) => setState(() {
                            _dragRaw += d.delta.dx / w * view;
                            final s = _snap(i, _dragRaw, view / w);
                            _dragOffset = s.offset;
                            _snapped = s.snapped;
                          }),
                    onHorizontalDragEnd: _recording
                        ? null
                        : (_) {
                            final o = _dragOffset.round();
                            setState(() => _dragging = null);
                            _setLayer(i, l.copyWith(offset: o), 'Slide layer');
                          },
                    child: CustomPaint(
                      painter: _LanePainter(
                        peaks: a?.peaks,
                        start: offset / view,
                        width: (a?.length ?? 0) / view,
                        playhead: _position / view,
                        color: l.muted
                            ? scheme.outline
                            : _dragging == i
                            ? (_snapped ? scheme.error : scheme.tertiary)
                            : scheme.primary,
                        background: scheme.surfaceContainerHighest,
                        gridStep: sampleRate / view,
                        gridColor: scheme.outline,
                        onset: (a?.onset ?? 0) / view,
                        onsetColor: scheme.tertiary,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  );
                },
              ),
            ),
            Row(
              children: [
                const Icon(Icons.volume_down, size: 18),
                Expanded(
                  child: Slider(
                    value: l.volume,
                    max: 1.5,
                    onChanged: _recording
                        ? null
                        : (v) => _setLayer(
                            i,
                            l.copyWith(volume: v),
                            'Volume',
                            coalesce: true,
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Seek bar: the stack's extent and the playhead, as fractions of the view.
class _RulerPainter extends CustomPainter {
  _RulerPainter({
    required this.length,
    required this.playhead,
    required this.color,
    required this.track,
  });

  final double length, playhead;
  final Color color, track;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, r),
      Paint()..color = track,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width * length.clamp(0.0, 1.0), size.height),
        r,
      ),
      Paint()..color = color.withValues(alpha: 0.3),
    );
    final x = size.width * playhead.clamp(0.0, 1.0);
    canvas.drawRect(
      Rect.fromLTWH(x - 1.5, 0, 3, size.height),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_RulerPainter o) =>
      o.length != length || o.playhead != playhead || o.color != color;
}

/// One layer's waveform, drawn where it sits in the stack.
class _LanePainter extends CustomPainter {
  _LanePainter({
    required this.peaks,
    required this.start,
    required this.width,
    required this.playhead,
    required this.color,
    required this.background,
    required this.gridStep,
    required this.gridColor,
    required this.onset,
    required this.onsetColor,
  });

  final double onset; // sound start, as a fraction of the width
  final Color onsetColor;
  final double gridStep; // one second, as a fraction of the width
  final Color gridColor;
  final Peaks? peaks;
  final double start, width, playhead;
  final Color color, background;

  @override
  void paint(Canvas canvas, Size size) {
    final left = start * size.width, w = width * size.width;
    final rect = Rect.fromLTWH(left, 0, math.max(2, w), size.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()..color = background,
    );
    final p = peaks;
    if (p != null && w > 1) {
      canvas.save();
      canvas.clipRect(rect);
      canvas.translate(left, 0);
      WaveformPainter(
        minMax: p.minMax,
        firstBlock: 0,
        blockCount: p.blocks,
        color: color,
      ).paint(canvas, Size(w, size.height));
      canvas.restore();
    }
    // 1-second grid, drawn over the layer so it shows through (the snap
    // points; human, 2026-11-14: it was hidden under the lane background).
    if (gridStep > 0) {
      final g = Paint()..color = gridColor.withValues(alpha: 0.7);
      for (var x = 0.0; x <= 1.0; x += gridStep) {
        canvas.drawRect(Rect.fromLTWH(x * size.width, 0, 1, size.height), g);
      }
    }
    // Where the sound starts: the anchor that snaps.
    if (w > 1) {
      final ox = left + onset * size.width;
      canvas.drawRect(
        Rect.fromLTWH(ox - 1, 0, 2, size.height),
        Paint()..color = onsetColor,
      );
      canvas.drawPath(
        Path()
          ..moveTo(ox - 5, 0)
          ..lineTo(ox + 5, 0)
          ..lineTo(ox, 7)
          ..close(),
        Paint()..color = onsetColor,
      );
    }
    final x = size.width * playhead;
    canvas.drawRect(
      Rect.fromLTWH(x - 1, 0, 2, size.height),
      Paint()..color = color.withValues(alpha: 0.8),
    );
  }

  @override
  bool shouldRepaint(_LanePainter o) =>
      o.onset != onset ||
      o.start != start ||
      o.width != width ||
      o.playhead != playhead ||
      o.color != color ||
      o.peaks != peaks;
}
