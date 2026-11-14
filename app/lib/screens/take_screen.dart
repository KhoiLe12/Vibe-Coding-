// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// One take (wiki/features/playback-and-scrub.md, wiki/features/chop.md):
// - one finger drag: tape-style scrub, relative to the playhead, speed capped
//   independent of zoom (wiki/decisions/d009-scrub-style.md)
// - tap: jump there
// - long-press + drag: select (loop, delete, trim, duplicate)
// - two fingers: pinch to zoom, drag to pan; overview strip shows where you are
// - ⏪5 / 5⏩: tap to jump 5 s, hold to rewind / fast-forward at 4×
// - ✂ split at the playhead; clip strip: tap to select a clip, long-press and
//   drag to reorder; undo/redo; revert to original (wiki/decisions/
//   d012-chop-model.md)

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocket_audio/pocket_audio.dart';

import '../audio/audio_control.dart';
import '../edit/edit_list.dart';
import '../takes/take_store.dart';
import '../widgets/waveform.dart';

const _shuttleSpeed = 4.0;

/// Scrub moves the tape relative to where it is, at most this many frames per
/// pixel of finger travel (10 ms). Zoomed out, a pixel can be seconds of
/// audio, which made scrubbing race at max speed and sound unintelligible;
/// with the cap an unhurried drag (~100 px/s) plays at about real time, at
/// any zoom. Zoomed in closer than this, the needle stays under the finger.
const _maxScrubFramesPerPixel = sampleRate / 100;
const _minViewSeconds = 0.25;

/// Cuts snap to a zero crossing within ±5 ms of the recording (d012).
const _snapRadius = 240;

class TakeScreen extends StatefulWidget {
  const TakeScreen({
    super.key,
    required this.store,
    required this.take,
    this.sinceStop,
    this.message,
  });

  final TakeStore store;
  final Take take;

  /// Started when the user pressed stop; measures stop → editor shown
  /// (acceptance: within 300 ms, wiki/features/record.md).
  final Stopwatch? sinceStop;
  final String? message;

  @override
  State<TakeScreen> createState() => _TakeScreenState();
}

class _TakeScreenState extends State<TakeScreen> {
  Peaks? _sourcePeaks;
  Peaks? _peaks; // timeline peaks for the current edit list
  String? _error;
  int? _openedMs;
  Timer? _ticker;
  bool _playing = false;
  int _position = 0;
  late EditHistory _history;
  bool _applying = false;

  // Visible window, in timeline frames.
  double _viewStart = 0;
  late double _viewSpan;

  // Gestures.
  bool _scrubbing = false;
  bool _zooming = false;
  double _zoomBaseScale = 1;
  double _zoomBaseSpan = 1;
  double _zoomFocusFrame = 0;
  int? _selAnchor;
  double _scrubAnchorFrame = 0;
  double _scrubStartX = 0;

  // Selection (timeline frames), and whether it loops.
  int? _selStart, _selEnd;
  bool _loopOn = false;

  EditList get _edits => _history.current;
  int get _length => _edits.length;

  @override
  void initState() {
    super.initState();
    final edits = widget.store.loadEdits(widget.take.id, widget.take.frames);
    _history = EditHistory(edits);
    _viewSpan = math.max(1, edits.length).toDouble();
    try {
      AudioControl.useOutput();
      PocketAudio.openTake(widget.take.wav.path);
      if (!edits.isWhole(widget.take.frames)) _pushClips(edits);
    } on PocketAudioException catch (e) {
      _error = 'Could not open this take for playback (${e.message}).';
    }
    widget.store
        .loadPeaks(widget.take)
        .then(
          (p) {
            if (!mounted) return;
            setState(() {
              _sourcePeaks = p;
              _peaks = timelinePeaks(p, _edits);
            });
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final sw = widget.sinceStop;
              if (sw != null && _openedMs == null && mounted) {
                setState(() => _openedMs = sw.elapsedMilliseconds);
              }
            });
          },
          onError: (Object e) {
            if (mounted) {
              setState(() => _error = 'Could not read the waveform ($e).');
            }
          },
        );
    _ticker = Timer.periodic(const Duration(milliseconds: 33), (_) => _tick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    if (PocketAudio.isScrubbing) PocketAudio.endScrub();
    PocketAudio.closeTake();
    AudioControl.release();
    super.dispose();
  }

  void _tick() {
    final playing = PocketAudio.isPlaying;
    final position = PocketAudio.playbackPosition;
    if (playing == _playing && position == _position) return;
    setState(() {
      _playing = playing;
      _position = position;
      // Follow the playhead when it leaves the window (not while the user
      // is steering it).
      if (!_scrubbing && !_zooming && _viewSpan < _length) {
        if (position < _viewStart || position > _viewStart + _viewSpan) {
          _setView(position - 0.1 * _viewSpan, _viewSpan);
        }
      }
    });
  }

  void _setView(double start, double span) {
    final len = math.max(1, _length).toDouble();
    final minSpan = _minViewSeconds * sampleRate;
    span = span.clamp(math.min(minSpan, len), len);
    _viewSpan = span;
    _viewStart = start.clamp(0.0, math.max(0.0, len - span));
  }

  int _frameAt(double dx, double width) =>
      (_viewStart + dx / width * _viewSpan).round().clamp(0, _length);

  // ---- editing (wiki/decisions/d012-chop-model.md) ----

  static void _pushClips(EditList e) => PocketAudio.setClips([
    for (final c in e.clips) (start: c.start, end: c.end, gain: c.gain),
  ]);

  /// Moves timeline frame [t] to the nearest zero crossing of the recording
  /// within ±5 ms, without leaving its clip.
  int _snap(int t) {
    if (t <= 0 || t >= _length) return t;
    final l = _edits.locate(t);
    final c = _edits.clips[l.index];
    final s = c.start + l.offset;
    final z = PocketAudio.zeroCrossing(
      s,
      radius: _snapRadius,
    ).clamp(c.start, c.end);
    return t + (z - s);
  }

  Future<void> _apply(
    String label,
    EditList next, {
    required int position,
    ({int start, int end})? select,
    bool zoomOut = false,
  }) async {
    // Decide before the history changes: _length follows the history.
    final showWhole = zoomOut || _showingWhole;
    if (_applying || !_history.push(label, next)) return;
    await _commit(
      next,
      position: position,
      select: select,
      showWhole: showWhole,
    );
  }

  /// Whether the whole take is in view (then edits keep it that way).
  bool get _showingWhole => _viewSpan >= _length;

  /// Swaps the edit list into the engine. While playing it fades out first and
  /// back in after, so applying an edit never clicks.
  Future<void> _commit(
    EditList list, {
    required int position,
    required bool showWhole,
    ({int start, int end})? select,
  }) async {
    _applying = true;
    final wasPlaying = PocketAudio.isPlaying;
    if (wasPlaying) {
      PocketAudio.playing = false;
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    _pushClips(list);
    PocketAudio.seek(position.clamp(0, list.length));
    widget.store.saveEdits(widget.take, list);
    setState(() {
      final src = _sourcePeaks;
      if (src != null) _peaks = timelinePeaks(src, list);
      _selStart = select?.start;
      _selEnd = select?.end;
      if (select == null) _loopOn = false;
      _setView(
        showWhole ? 0 : _viewStart,
        showWhole ? list.length.toDouble() : _viewSpan,
      );
      _position = position.clamp(0, list.length);
    });
    if (_loopOn && select != null) {
      PocketAudio.setLoop(select.start, select.end);
    } else {
      PocketAudio.clearLoop();
    }
    if (wasPlaying) PocketAudio.playing = true;
    _applying = false;
  }

  void _split() {
    final t = _snap(_position);
    _apply('Split', _edits.split(t), position: _position);
  }

  ({int a, int b})? get _snappedSelection {
    final s = _selStart, e = _selEnd;
    if (s == null || e == null || e <= s) return null;
    return (a: _snap(s), b: _snap(e));
  }

  void _deleteSelection() {
    final sel = _snappedSelection;
    if (sel == null) return;
    if (sel.a <= 0 && sel.b >= _length) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "That's the whole take — use Delete take in the menu instead.",
          ),
        ),
      );
      return;
    }
    final p = _position;
    final pos = p < sel.a
        ? p
        : p >= sel.b
        ? p - (sel.b - sel.a)
        : sel.a;
    _apply('Delete', _edits.delete(sel.a, sel.b), position: pos);
  }

  void _trimToSelection() {
    final sel = _snappedSelection;
    if (sel == null) return;
    final p = _position;
    final pos = p >= sel.a && p < sel.b ? p - sel.a : 0;
    _apply('Trim', _edits.trim(sel.a, sel.b), position: pos);
  }

  void _duplicateSelection() {
    final sel = _snappedSelection;
    if (sel == null) return;
    final len = sel.b - sel.a;
    // Select the copy, so pressing Duplicate again keeps repeating it.
    _apply(
      'Duplicate',
      _edits.duplicate(sel.a, sel.b),
      position: _position < sel.b ? _position : _position + len,
      select: (start: sel.b, end: sel.b + len),
      zoomOut: true, // always show the whole take after duplicating
    );
  }

  void _moveClip(int from, int to) {
    final before = _edits;
    final after = before.move(from, to);
    // Keep the playhead on the same audio.
    final l = before.locate(_position);
    var pos = _position;
    if (l.index < before.clips.length) {
      final order = [for (var i = 0; i < before.clips.length; i++) i];
      order.insert(to.clamp(0, order.length - 1), order.removeAt(from));
      pos = after.startOf(order.indexOf(l.index)) + l.offset;
    }
    _apply('Move clip', after, position: pos);
  }

  /// Tap on a clip block: selects it, or — if something outside it is already
  /// selected — extends the selection to cover both (a contiguous block).
  /// Tapping a clip inside the selection selects just that clip again.
  void _selectClip(int index) {
    final cs = _edits.startOf(index);
    final ce = cs + _edits.clips[index].length;
    var start = cs, end = ce;
    final s = _selStart, e = _selEnd;
    if (s != null && e != null && !(cs >= s && ce <= e)) {
      start = math.min(s, cs);
      end = math.max(e, ce);
    }
    setState(() {
      _selStart = start;
      _selEnd = end;
    });
    if (_loopOn) PocketAudio.setLoop(start, end);
  }

  Future<void> _undo() async {
    if (_applying || !_history.canUndo) return;
    final showWhole = _showingWhole;
    final list = _history.undo();
    await _commit(
      list,
      position: math.min(_position, list.length),
      showWhole: showWhole,
    );
  }

  Future<void> _redo() async {
    if (_applying || !_history.canRedo) return;
    final showWhole = _showingWhole;
    final list = _history.redo();
    await _commit(
      list,
      position: math.min(_position, list.length),
      showWhole: showWhole,
    );
  }

  void _goToSelectionStart() {
    final s = _selStart;
    if (s == null) return;
    PocketAudio.seek(s);
    _tick();
  }

  void _revert() {
    final s = _edits.sourceAt(_position) ?? 0;
    _apply(
      'Revert to original',
      EditList.whole(widget.take.frames),
      position: s,
    );
  }

  // ---- transport ----

  void _toggle() {
    if (PocketAudio.isPlaying) {
      PocketAudio.playing = false;
    } else {
      final loop = PocketAudio.loop;
      if (loop != null && (_position < loop.start || _position >= loop.end)) {
        PocketAudio.seek(loop.start);
      } else if (PocketAudio.playbackFinished) {
        PocketAudio.seek(0);
      }
      PocketAudio.playing = true;
    }
    _tick();
  }

  void _skip(int seconds) {
    PocketAudio.seek((_position + seconds * sampleRate).clamp(0, _length));
    _tick();
  }

  void _shuttle(double speed) {
    PocketAudio.beginScrub();
    PocketAudio.shuttle = speed;
    setState(() => _scrubbing = true);
  }

  void _endShuttle() {
    if (!_scrubbing) return;
    PocketAudio.endScrub();
    setState(() => _scrubbing = false);
  }

  // ---- waveform gestures ----

  void _onScaleStart(ScaleStartDetails d, double width) {
    if (d.pointerCount >= 2) {
      _startZoom(d.localFocalPoint.dx, width, 1);
    } else {
      PocketAudio.beginScrub();
      _scrubAnchorFrame = PocketAudio.playbackPosition.toDouble();
      _scrubStartX = d.localFocalPoint.dx;
      PocketAudio.scrubTarget = _scrubAnchorFrame;
      setState(() => _scrubbing = true);
    }
  }

  void _startZoom(double focalX, double width, double scale) {
    if (_scrubbing) {
      PocketAudio.endScrub();
      _scrubbing = false;
    }
    _zooming = true;
    _zoomBaseScale = scale;
    _zoomBaseSpan = _viewSpan;
    _zoomFocusFrame = _viewStart + focalX / width * _viewSpan;
  }

  void _onScaleUpdate(ScaleUpdateDetails d, double width) {
    if (d.pointerCount >= 2) {
      if (!_zooming) {
        _startZoom(d.localFocalPoint.dx, width, d.horizontalScale);
      }
      final span = _zoomBaseSpan * _zoomBaseScale / d.horizontalScale;
      setState(() {
        _setView(_zoomFocusFrame - d.localFocalPoint.dx / width * span, span);
      });
    } else if (_scrubbing) {
      final perPixel = math.min(_viewSpan / width, _maxScrubFramesPerPixel);
      PocketAudio.scrubTarget =
          (_scrubAnchorFrame + (d.localFocalPoint.dx - _scrubStartX) * perPixel)
              .clamp(0.0, _length.toDouble());
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_scrubbing) {
      PocketAudio.endScrub();
      setState(() => _scrubbing = false);
    }
    _zooming = false;
  }

  void _onLongPressStart(LongPressStartDetails d, double width) {
    final f = _frameAt(d.localPosition.dx, width);
    setState(() {
      _selAnchor = f;
      _selStart = _selEnd = f;
    });
  }

  void _onLongPressMove(LongPressMoveUpdateDetails d, double width) {
    final f = _frameAt(d.localPosition.dx, width);
    setState(() {
      _selStart = math.min(_selAnchor!, f);
      _selEnd = math.max(_selAnchor!, f);
    });
  }

  void _onLongPressEnd() {
    final s = _selStart!, e = _selEnd!;
    _selAnchor = null;
    if (e - s < sampleRate ~/ 20) {
      // Under 50 ms: treat as a cancelled selection.
      _clearSelection();
      return;
    }
    setState(() => _loopOn = true);
    PocketAudio.setLoop(s, e);
    if (PocketAudio.isPlaying && (_position < s || _position >= e)) {
      PocketAudio.seek(s);
    }
  }

  void _setLoopOn(bool on) {
    setState(() => _loopOn = on);
    if (on && _selStart != null) {
      PocketAudio.setLoop(_selStart!, _selEnd!);
    } else {
      PocketAudio.clearLoop();
    }
  }

  void _clearSelection() {
    PocketAudio.clearLoop();
    setState(() {
      _selAnchor = null;
      _selStart = _selEnd = null;
      _loopOn = false;
    });
  }

  Future<void> _deleteTake() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this take?'),
        content: Text(
          'The recording (${formatDuration(Duration(microseconds: widget.take.frames * 1000000 ~/ sampleRate))}) '
          'and its edits will be deleted from this phone. This cannot be '
          'undone.',
        ),
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
    PocketAudio.closeTake();
    widget.store.delete(widget.take);
    Navigator.of(context).pop();
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final peaks = _peaks;
    final selColor = scheme.tertiary.withValues(alpha: _loopOn ? 0.35 : 0.18);
    final hasSelection = _selStart != null && _selAnchor == null;

    double toView(num frame) => (frame - _viewStart) / _viewSpan;
    final joins = <int>[
      for (var i = 1; i < _edits.clips.length; i++) _edits.startOf(i),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(takeTitle(widget.take)),
        actions: [
          IconButton(
            key: const Key('undo'),
            tooltip: _history.canUndo ? 'Undo ${_history.undoLabel}' : 'Undo',
            onPressed: _history.canUndo ? _undo : null,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            key: const Key('redo'),
            tooltip: _history.canRedo ? 'Redo ${_history.redoLabel}' : 'Redo',
            onPressed: _history.canRedo ? _redo : null,
            icon: const Icon(Icons.redo),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => v == 'revert' ? _revert() : _deleteTake(),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'revert',
                enabled: !_edits.isWhole(widget.take.frames),
                child: const Text('Revert to original'),
              ),
              const PopupMenuItem(value: 'delete', child: Text('Delete take')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.message != null || _error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error ?? widget.message!,
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              if (peaks != null) ...[
                _overview(peaks, scheme, selColor),
                const SizedBox(height: 8),
              ],
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: peaks == null
                      ? const Center(child: CircularProgressIndicator())
                      : LayoutBuilder(
                          builder: (context, box) {
                            final w = box.maxWidth;
                            final bf = peaks.blockFrames;
                            final playhead = toView(_position);
                            return GestureDetector(
                              key: const Key('waveform'),
                              behavior: HitTestBehavior.opaque,
                              onTapUp: (d) {
                                PocketAudio.seek(
                                  _frameAt(d.localPosition.dx, w),
                                );
                                _tick();
                              },
                              onScaleStart: (d) => _onScaleStart(d, w),
                              onScaleUpdate: (d) => _onScaleUpdate(d, w),
                              onScaleEnd: _onScaleEnd,
                              onLongPressStart: (d) => _onLongPressStart(d, w),
                              onLongPressMoveUpdate: (d) =>
                                  _onLongPressMove(d, w),
                              onLongPressEnd: (_) => _onLongPressEnd(),
                              child: ClipRect(
                                child: CustomPaint(
                                  painter: WaveformPainter(
                                    minMax: peaks.minMax,
                                    firstBlock: (_viewStart / bf).floor(),
                                    blockCount: (_viewSpan / bf).ceil(),
                                    color: scheme.primary,
                                    playhead: playhead >= 0 && playhead <= 1
                                        ? playhead
                                        : null,
                                    playheadColor: _scrubbing
                                        ? scheme.tertiary
                                        : scheme.onSurface,
                                    markers: [for (final j in joins) toView(j)],
                                    markerColor: scheme.secondary,
                                    bands: [
                                      if (_selStart != null)
                                        (
                                          from: toView(_selStart!),
                                          to: toView(_selEnd!),
                                          color: selColor,
                                        ),
                                    ],
                                  ),
                                  child: const SizedBox.expand(),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
              if (_edits.clips.length > 1) ...[
                const SizedBox(height: 8),
                _clipStrip(scheme),
              ],
              const SizedBox(height: 4),
              SizedBox(
                height: 48,
                child: hasSelection
                    ? _selectionBar(theme)
                    : Center(
                        child: Text(
                          _scrubbing
                              ? 'Scrubbing'
                              : 'Drag to scrub · long-press + drag to select '
                                    '· pinch to zoom',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
              ),
              Text(
                '${formatDuration(Duration(milliseconds: _position * 1000 ~/ sampleRate))}'
                ' / ${formatDuration(Duration(milliseconds: _length * 1000 ~/ sampleRate))}',
                key: const Key('position'),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (_openedMs != null)
                Text(
                  'Opened ${_openedMs!} ms after stop',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton.outlined(
                    key: const Key('split'),
                    tooltip: 'Split at playhead',
                    onPressed: _error == null && _position > 0 ? _split : null,
                    icon: const Icon(Icons.content_cut),
                  ),
                  const SizedBox(width: 16),
                  _HoldButton(
                    key: const Key('back5'),
                    icon: Icons.replay_5,
                    label: 'Back 5 seconds; hold to rewind',
                    enabled: _error == null,
                    onTap: () => _skip(-5),
                    onHoldStart: () => _shuttle(-_shuttleSpeed),
                    onHoldEnd: _endShuttle,
                  ),
                  const SizedBox(width: 16),
                  SizedBox.square(
                    dimension: 88,
                    child: FilledButton(
                      key: const Key('play'),
                      style: FilledButton.styleFrom(
                        shape: const CircleBorder(),
                      ),
                      onPressed: _error == null ? _toggle : null,
                      child: Icon(
                        _playing ? Icons.pause : Icons.play_arrow,
                        size: 52,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  _HoldButton(
                    key: const Key('fwd5'),
                    icon: Icons.forward_5,
                    label: 'Forward 5 seconds; hold to fast-forward',
                    enabled: _error == null,
                    onTap: () => _skip(5),
                    onHoldStart: () => _shuttle(_shuttleSpeed),
                    onHoldEnd: _endShuttle,
                  ),
                  const SizedBox(width: 64),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _overview(Peaks peaks, ColorScheme scheme, Color selColor) {
    final len = math.max(1, _length);
    return SizedBox(
      height: 36,
      child: LayoutBuilder(
        builder: (context, box) {
          void centre(double dx) => setState(() {
            final f = dx / box.maxWidth * len;
            _setView(f - _viewSpan / 2, _viewSpan);
          });
          return GestureDetector(
            key: const Key('overview'),
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => centre(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => centre(d.localPosition.dx),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: ColoredBox(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                child: CustomPaint(
                  painter: WaveformPainter(
                    minMax: peaks.minMax,
                    firstBlock: 0,
                    blockCount: peaks.blocks,
                    color: scheme.primary.withValues(alpha: 0.7),
                    playhead: _position / len,
                    playheadColor: scheme.onSurface,
                    bands: [
                      if (_viewSpan < _length)
                        (
                          from: _viewStart / len,
                          to: (_viewStart + _viewSpan) / len,
                          color: scheme.primary.withValues(alpha: 0.2),
                        ),
                      if (_selStart != null)
                        (
                          from: _selStart! / len,
                          to: _selEnd! / len,
                          color: selColor,
                        ),
                    ],
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// One block per clip, proportional to its length; tap selects the clip,
  /// long-press and drag reorders.
  Widget _clipStrip(ColorScheme scheme) {
    final clips = _edits.clips;
    final playingIndex = _edits.locate(_position).index;
    return SizedBox(
      height: 40,
      child: LayoutBuilder(
        builder: (context, box) => ReorderableListView.builder(
          key: const Key('clips'),
          scrollDirection: Axis.horizontal,
          itemCount: clips.length,
          onReorderItem: _moveClip,
          proxyDecorator: (child, _, _) =>
              Material(elevation: 6, color: Colors.transparent, child: child),
          itemBuilder: (context, i) {
            final w = math.max(
              36.0,
              box.maxWidth * clips[i].length / math.max(1, _length) - 4,
            );
            final selected =
                _selStart == _edits.startOf(i) &&
                _selEnd == _edits.startOf(i) + clips[i].length;
            return Padding(
              key: ValueKey('clip-$i'),
              padding: const EdgeInsets.only(right: 4),
              child: GestureDetector(
                onTap: () => _selectClip(i),
                child: Container(
                  width: w,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected
                        ? scheme.tertiaryContainer
                        : i == playingIndex
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _selectionBar(ThemeData theme) {
    // Seven controls must fit a phone's width: compact buttons.
    return IconButtonTheme(
      data: IconButtonThemeData(
        style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
      ),
      child: _selectionRow(theme),
    );
  }

  Widget _selectionRow(ThemeData theme) {
    return Row(
      children: [
        Expanded(
          child: Text(
            '${_fmtPrecise(_selStart!)} – ${_fmtPrecise(_selEnd!)}',
            style: theme.textTheme.bodySmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        IconButton(
          key: const Key('to-sel-start'),
          tooltip: 'Playhead to start of selection',
          onPressed: _goToSelectionStart,
          icon: const Icon(Icons.first_page),
        ),
        IconButton(
          key: const Key('loop'),
          tooltip: _loopOn ? 'Stop looping' : 'Loop selection',
          isSelected: _loopOn,
          onPressed: () => _setLoopOn(!_loopOn),
          icon: const Icon(Icons.repeat),
          selectedIcon: const Icon(Icons.repeat_on),
        ),
        IconButton(
          key: const Key('delete-sel'),
          tooltip: 'Delete selection',
          onPressed: _deleteSelection,
          icon: const Icon(Icons.delete_outline),
        ),
        IconButton(
          key: const Key('trim'),
          tooltip: 'Trim to selection',
          onPressed: _trimToSelection,
          icon: const Icon(Icons.crop),
        ),
        IconButton(
          key: const Key('duplicate'),
          tooltip: 'Duplicate selection',
          onPressed: _duplicateSelection,
          icon: const Icon(Icons.copy_all),
        ),
        IconButton(
          tooltip: 'Clear selection',
          onPressed: _clearSelection,
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }

  String _fmtPrecise(int frame) {
    final ms = frame * 1000 ~/ sampleRate;
    final m = ms ~/ 60000, s = (ms ~/ 1000) % 60, t = (ms ~/ 100) % 10;
    return '$m:${s.toString().padLeft(2, '0')}.$t';
  }
}

/// Round button: tap for one action, press-and-hold for a continuous one.
class _HoldButton extends StatelessWidget {
  const _HoldButton({
    super.key,
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldEnd,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap, onHoldStart, onHoldEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        onLongPressStart: enabled ? (_) => onHoldStart() : null,
        onLongPressEnd: enabled ? (_) => onHoldEnd() : null,
        onLongPressCancel: enabled ? onHoldEnd : null,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.secondaryContainer,
          ),
          child: Icon(icon, size: 32, color: scheme.onSecondaryContainer),
        ),
      ),
    );
  }
}

String takeTitle(Take take) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final c = take.created;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${c.day} ${months[c.month - 1]} · ${two(c.hour)}:${two(c.minute)}';
}
