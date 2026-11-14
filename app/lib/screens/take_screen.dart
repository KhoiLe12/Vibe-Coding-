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
// - pitch & tempo for the whole take, rendered in the background
//   (wiki/decisions/d013-transpose-tempo-design.md)
// - sampling tools (M7, wiki/decisions/d016-sampling-tools.md): varispeed in
//   the pitch/tempo sheet; reverse, normalize, trim silence on the selection
//   or whole take (tools button); fade in / out by dragging the handles in
//   the top corners of the take or selection; export one-shot / loop /
//   slices and share (menu)
//
// Two time domains: the engine (and so positions, selection, loop and view
// here) runs in *display* frames — the render's timing when a stretched
// render is playing. The edit list works in *edit* frames — the recording's
// timing. _toEdit / _toDisplay convert with the time ratio (tempo ×
// varispeed) of what is playing.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pocket_audio/pocket_audio.dart';
import 'package:share_plus/share_plus.dart';

import '../audio/audio_control.dart';
import '../edit/edit_list.dart';
import '../edit/render_cache.dart';
import '../edit/sample_export.dart';
import '../stack/bounce.dart';
import '../takes/take_store.dart';
import '../tempo/detect.dart';
import '../tempo/grid.dart';
import '../widgets/tempo_controls.dart';
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

  /// Timeline length as the engine plays it (display frames).
  int _length = 0;

  // Rendering (M4). _active is what the engine plays from: a render of the
  // recording at some Tune, or null for the recording itself.
  Render? _active;
  Render? _pending;
  int _pendingJob = -1;
  double _renderProgress = 0;
  String? _renderError;
  Timer? _renderTimer;
  final _renderClock = Stopwatch();

  /// "Rendered 1:00 of audio in 0.8 s" — the M4 speed criterion, measured
  /// on the phone.
  String? _lastRender;

  /// Recording frames per displayed frame (tempo × varispeed) of what plays.
  double get _tempo => _active?.tune.timeRatio ?? 1.0;

  /// A tool or export is working in the background.
  String? _busy;
  int _exportFormat = 0;
  ExportKind _exportKind = ExportKind.oneShot;
  double _silenceDb = -48;

  // A fade handle being dragged: which one, and its length (display frames).
  ({bool fadeIn, int frames})? _fadeDrag;
  static const double _handleSize = 18;

  /// Where the last finger went down on the waveform (the scale gesture
  /// starts only after the finger has moved).
  Offset? _downAt;
  // Beat grid (M5b, d017): snap to beats, click with playback.
  static bool _snapBeats = true;
  static bool _click = false;

  /// The take's grid (edit frames), and as displayed (through pitch/tempo).
  Grid? get _grid => _edits.grid;
  Grid? get _viewGrid => _grid?.scaled(_tempo);
  bool get _snapping => _snapBeats && _grid != null;

  /// Nearest beat to display frame [f] when snapping, else [f].
  int _beatSnap(int f) =>
      _snapping ? _viewGrid!.nearestBeat(f).clamp(0, _length) : f;

  int _toEdit(num t) => (t * _tempo).round();
  int _toDisplay(num e) => (e / _tempo).round();

  /// This screen's claim on the player (AudioControl.claimPlayer).
  late final int _playerToken;

  @override
  void initState() {
    super.initState();
    _playerToken = AudioControl.claimPlayer();
    final edits = widget.store.loadEdits(
      widget.take.editsId,
      widget.take.frames,
      clamp: widget.take.isStackMix,
    );
    _history = EditHistory(edits);
    _viewSpan = math.max(1, edits.length).toDouble();
    // Starting audio can fail right after launch on iOS; play retries
    // (AudioControl.ensureOutput), so that is not an error for the take.
    AudioControl.ensureOutput();
    try {
      PocketAudio.openTake(widget.take.wav.path);
      _pushClips(edits);
      _viewSpan = math.max(1, _length).toDouble();
      // After the first frame: _ensureRender may call setState.
      if (!edits.tune.isIdentity) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _ensureRender());
      }
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
    _renderTimer?.cancel();
    if (_pending != null) PocketAudio.cancelRender();
    if (AudioControl.ownsPlayer(_playerToken) && PocketAudio.isScrubbing) {
      PocketAudio.endScrub();
    }
    if (AudioControl.ownsPlayer(_playerToken)) Metronome.follow(false);
    AudioControl.releasePlayer(_playerToken);
    super.dispose();
  }

  void _tick() {
    _pollRender();
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

  /// Hands the edit list to the engine: from the active render if it covers
  /// the clips, else from the recording (and the render is dropped).
  void _pushClips(EditList e) {
    final need = RenderCache.neededRange(e, widget.take.frames);
    final a = _active;
    if (a != null && a.covers(need.start, need.end)) {
      try {
        _length = PocketAudio.setClips(a.clipsFor(e), source: a.path);
        return;
      } on PocketAudioException {
        // Render file vanished (cache trimmed): fall back to the recording.
      }
    }
    _active = null;
    _length = PocketAudio.setClips([for (final c in e.clips) c.toPlay()]);
  }

  // ---- rendering (wiki/decisions/d013-transpose-tempo-design.md) ----

  /// Debounced: rapid taps only render the final value.
  void _scheduleRender() {
    _renderTimer?.cancel();
    _renderTimer = Timer(const Duration(milliseconds: 300), _ensureRender);
  }

  /// Makes sure the engine will play the edit list at its Tune: switches to
  /// a cached render or the recording right away, or starts a render.
  void _ensureRender() {
    if (!mounted) return;
    final e = _edits;
    final tune = e.tune;
    if (tune.isIdentity) {
      if (_pending != null) PocketAudio.cancelRender();
      _pending = null;
      if (_active != null) _switchTo(null);
      setState(() => _renderError = null);
      return;
    }
    final need = RenderCache.neededRange(e, widget.take.frames);
    final a = _active;
    if (a != null && a.tune == tune && a.covers(need.start, need.end)) return;
    final renders = widget.store.renders;
    final cached = renders.find(widget.take.id, tune, need.start, need.end);
    if (cached != null) {
      if (_pending != null) PocketAudio.cancelRender();
      _pending = null;
      _switchTo(cached);
      return;
    }
    final plan = renders.planFor(widget.take.id, tune, need.start, need.end);
    if (_pending?.path == plan.path) return; // already on it
    renders.trim(keep: {if (a != null) a.path});
    _pendingJob = PocketAudio.startRender(
      input: widget.take.wav.path,
      start: plan.start,
      end: plan.end,
      output: plan.path,
      semitones: tune.semitones,
      tempo: tune.tempo,
      formant: tune.formant,
      speed: tune.speed,
    );
    _renderClock
      ..reset()
      ..start();
    setState(() {
      _pending = plan;
      _renderProgress = 0;
      _renderError = null;
      _lastRender = null;
    });
  }

  void _pollRender() {
    final p = _pending;
    if (p == null || PocketAudio.renderJob != _pendingJob) return;
    switch (PocketAudio.renderState) {
      case RenderState.running:
        final prog = PocketAudio.renderProgress;
        if ((prog - _renderProgress).abs() > 0.01) {
          setState(() => _renderProgress = prog);
        }
      case RenderState.done:
        _pending = null;
        final secs = (p.end - p.start) / sampleRate;
        _lastRender =
            'Rendered ${formatDuration(Duration(milliseconds: (secs * 1000).round()))} '
            'in ${(_renderClock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s';
        if (p.tune == _edits.tune) {
          _switchTo(p);
        } else {
          _ensureRender(); // settings moved on meanwhile
        }
        setState(() {});
      case RenderState.failed:
        setState(() {
          _pending = null;
          _renderError = 'Could not render the new pitch/tempo.';
        });
      case RenderState.cancelled:
      case RenderState.idle:
        setState(() => _pending = null);
    }
  }

  /// Switches what the engine plays from (a render, or null = recording)
  /// at the same musical position, fading around the swap.
  Future<void> _switchTo(Render? r) async {
    if (_applying) {
      // An edit is being applied; try again right after it.
      Future<void>.delayed(const Duration(milliseconds: 30), _ensureRender);
      return;
    }
    _applying = true;
    final wasPlaying = PocketAudio.isPlaying;
    if (wasPlaying) {
      PocketAudio.playing = false;
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    // Remember everything in edit frames, swap, convert back.
    final pos = _toEdit(_position);
    final sel = _selStart == null
        ? null
        : (start: _toEdit(_selStart!), end: _toEdit(_selEnd!));
    final whole = _showingWhole;
    final vStart = _toEdit(_viewStart), vSpan = _toEdit(_viewSpan);
    _active = r;
    _pushClips(_edits);
    PocketAudio.seek(_toDisplay(pos).clamp(0, _length));
    if (!mounted) return;
    setState(() {
      _position = _toDisplay(pos).clamp(0, _length);
      if (sel != null) {
        _selStart = _toDisplay(sel.start);
        _selEnd = _toDisplay(sel.end);
      }
      if (whole) {
        _setView(0, _length.toDouble());
      } else {
        _setView(vStart / _tempo, vSpan / _tempo);
      }
    });
    if (_loopOn && _selStart != null) {
      PocketAudio.setLoop(_selStart!, _selEnd!);
    }
    if (wasPlaying) PocketAudio.playing = true;
    _applying = false;
  }

  /// Changes the take's pitch/tempo (undoable; taps in a row coalesce).
  void _setTune(Tune next, String label) {
    _apply(
      label,
      _edits.withTune(next),
      position: _toEdit(_position),
      select: _selStart == null
          ? null
          : (start: _toEdit(_selStart!), end: _toEdit(_selEnd!)),
      coalesce: true,
    );
  }

  /// Moves edit frame [t] to the nearest zero crossing of the recording
  /// within ±5 ms, without leaving its clip.
  int _snap(int t) {
    if (t <= 0 || t >= _edits.length) return t;
    final l = _edits.locate(t);
    final c = _edits.clips[l.index];
    final s = c.boundaryAt(l.offset);
    final z = PocketAudio.zeroCrossing(
      s,
      radius: _snapRadius,
    ).clamp(c.start, c.end);
    // A reversed clip runs backwards through the recording.
    return t + (c.reverse ? s - z : z - s);
  }

  /// Records an edit and applies it. [position] and [select] are in *edit*
  /// frames (the recording's timing).
  Future<void> _apply(
    String label,
    EditList next, {
    required int position,
    ({int start, int end})? select,
    bool zoomOut = false,
    bool coalesce = false,
  }) async {
    // Decide before the history changes.
    final showWhole = zoomOut || _showingWhole;
    if (_applying || !_history.push(label, next, coalesce: coalesce)) return;
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
  /// back in after, so applying an edit never clicks. [position] and [select]
  /// are edit frames; they are converted once the engine's timing is known.
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
    final oldTempo = _tempo;
    final vStart = _viewStart * oldTempo, vSpan = _viewSpan * oldTempo;
    _pushClips(list);
    final pos = _toDisplay(position.clamp(0, list.length)).clamp(0, _length);
    PocketAudio.seek(pos);
    widget.store.saveEdits(widget.take, list);
    if (!mounted) return;
    setState(() {
      final src = _sourcePeaks;
      if (src != null) _peaks = timelinePeaks(src, list);
      _selStart = select == null ? null : _toDisplay(select.start);
      _selEnd = select == null ? null : _toDisplay(select.end);
      if (select == null) _loopOn = false;
      if (showWhole) {
        _setView(0, _length.toDouble());
      } else {
        _setView(vStart / _tempo, vSpan / _tempo);
      }
      _position = pos;
    });
    if (_loopOn && _selStart != null) {
      PocketAudio.setLoop(_selStart!, _selEnd!);
    } else {
      PocketAudio.clearLoop();
    }
    if (wasPlaying) PocketAudio.playing = true;
    _applying = false;
    _scheduleRender(); // pitch/tempo changed, or the edit needs more render
  }

  void _split() {
    final p = _toEdit(_position);
    // On a beat when snapping (exact, so bar-length slices stay exact; the
    // join's crossfade keeps it click-free), else at a zero crossing.
    final at = _snapping
        ? _grid!.nearestBeat(p).clamp(0, _edits.length)
        : _snap(p);
    _apply('Split', _edits.split(at), position: p);
  }

  /// The selection in edit frames: on beats when snapping (exact), else
  /// snapped to zero crossings.
  ({int a, int b})? get _snappedSelection {
    final s = _selStart, e = _selEnd;
    if (s == null || e == null || e <= s) return null;
    if (_snapping) {
      final g = _grid!;
      final a = g.nearestBeat(_toEdit(s)).clamp(0, _edits.length);
      final b = g.nearestBeat(_toEdit(e)).clamp(0, _edits.length);
      if (b > a) return (a: a, b: b);
    }
    return (a: _snap(_toEdit(s)), b: _snap(_toEdit(e)));
  }

  void _deleteSelection() {
    final sel = _snappedSelection;
    if (sel == null) return;
    if (sel.a <= 0 && sel.b >= _edits.length) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "That's the whole take — use Delete take in the menu instead.",
          ),
        ),
      );
      return;
    }
    final p = _toEdit(_position);
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
    final p = _toEdit(_position);
    final pos = p >= sel.a && p < sel.b ? p - sel.a : 0;
    _apply('Trim', _edits.trim(sel.a, sel.b), position: pos);
  }

  void _duplicateSelection() {
    final sel = _snappedSelection;
    if (sel == null) return;
    final len = sel.b - sel.a;
    final p = _toEdit(_position);
    // Select the copy, so pressing Duplicate again keeps repeating it.
    _apply(
      'Duplicate',
      _edits.duplicate(sel.a, sel.b),
      position: p < sel.b ? p : p + len,
      select: (start: sel.b, end: sel.b + len),
      zoomOut: true, // always show the whole take after duplicating
    );
  }

  void _moveClip(int from, int to) {
    final before = _edits;
    final after = before.move(from, to);
    // Keep the playhead on the same audio.
    final p = _toEdit(_position);
    final l = before.locate(p);
    var pos = p;
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
    final cs = _toDisplay(_edits.startOf(index));
    final ce = _toDisplay(_edits.startOf(index) + _edits.clips[index].length);
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
    final p = _toEdit(_position);
    final list = _history.undo();
    await _commit(
      list,
      position: math.min(p, list.length),
      showWhole: showWhole,
    );
  }

  Future<void> _redo() async {
    if (_applying || !_history.canRedo) return;
    final showWhole = _showingWhole;
    final p = _toEdit(_position);
    final list = _history.redo();
    await _commit(
      list,
      position: math.min(p, list.length),
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
    final s = _edits.sourceAt(_toEdit(_position)) ?? 0;
    _apply(
      'Revert to original',
      EditList.whole(widget.take.frames).withGrid(_grid), // keeps the tempo
      position: s,
    );
  }

  // ---- transport ----

  Future<void> _toggle() async {
    if (PocketAudio.isPlaying) {
      PocketAudio.playing = false;
    } else {
      if (!await AudioControl.ensureOutput()) {
        if (mounted) {
          setState(
            () => _error =
                'iOS did not let the app start audio. '
                'Try again in a moment.',
          );
        }
        return;
      }
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
    } else if (_handleAt(_downAt ?? d.localFocalPoint, width)
        case final fadeIn?) {
      setState(
        () => _fadeDrag = (fadeIn: fadeIn, frames: _fadeLength(fadeIn: fadeIn)),
      );
      _dragFade(fadeIn, d.localFocalPoint.dx, width);
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
    _fadeDrag = null; // a pinch cancels a half-dragged fade
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
    } else if (_fadeDrag case final f? when !_zooming) {
      _dragFade(f.fadeIn, d.localFocalPoint.dx, width);
    } else if (_scrubbing) {
      final perPixel = math.min(_viewSpan / width, _maxScrubFramesPerPixel);
      PocketAudio.scrubTarget =
          (_scrubAnchorFrame + (d.localFocalPoint.dx - _scrubStartX) * perPixel)
              .clamp(0.0, _length.toDouble());
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (!_zooming) _commitFade();
    if (_scrubbing) {
      PocketAudio.endScrub();
      setState(() => _scrubbing = false);
    }
    _zooming = false;
  }

  void _onLongPressStart(LongPressStartDetails d, double width) {
    if (_handleAt(d.localPosition, width) != null) return;
    final f = _beatSnap(_frameAt(d.localPosition.dx, width));
    setState(() {
      _selAnchor = f;
      _selStart = _selEnd = f;
    });
  }

  void _onLongPressMove(LongPressMoveUpdateDetails d, double width) {
    if (_selAnchor == null) return;
    final f = _beatSnap(_frameAt(d.localPosition.dx, width));
    setState(() {
      _selStart = math.min(_selAnchor!, f);
      _selEnd = math.max(_selAnchor!, f);
    });
  }

  void _onLongPressEnd() {
    if (_selAnchor == null) return;
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

  /// Saves what you hear (edits, pitch, tempo) as a new take.
  Future<void> _bounceEdited() async {
    final t = widget.store.newTake();
    try {
      await bounceStackInBackground(t.wav);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bounced to a new take in your list.')),
      );
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Bounce failed ($e).');
    }
  }

  // ---- sampling tools (M7, wiki/decisions/d016-sampling-tools.md) ----

  /// What a tool acts on, in edit frames: the selection (snapped) or the
  /// whole take.
  ({int a, int b, bool whole}) get _toolRange {
    final sel = _snappedSelection;
    return sel == null
        ? (a: 0, b: _edits.length, whole: true)
        : (a: sel.a, b: sel.b, whole: false);
  }

  void _toolDone(String label, EditList next, ({int a, int b, bool whole}) r) {
    _apply(
      label,
      next,
      position: _toEdit(_position).clamp(0, next.length),
      select: r.whole ? null : (start: r.a, end: r.b),
    );
  }

  void _reverse() {
    final r = _toolRange;
    _toolDone('Reverse', _edits.reverse(r.a, r.b), r);
  }

  // ---- fade handles (human, 2026-11-14: a needle per clip was still
  // clunky; fades sit at the start and end of the take or the selection) ----

  /// The region the fade handles act on: the selection, else the whole take.
  /// Display frames for drawing, edit frames (snapped) for the edit.
  ({int from, int to, int a, int b}) get _fadeRegion {
    final s = _selStart, e = _selEnd;
    final sel = _hasFadeSelection ? _snappedSelection : null;
    return sel == null
        ? (from: 0, to: _length, a: 0, b: _edits.length)
        : (from: s!, to: e!, a: sel.a, b: sel.b);
  }

  bool get _hasFadeSelection =>
      _selStart != null && _selAnchor == null && _selEnd! > _selStart!;

  /// Fade lengths in display frames: while a handle is dragged, its live
  /// value.
  int _fadeLength({required bool fadeIn}) {
    final d = _fadeDrag;
    if (d != null && d.fadeIn == fadeIn) return d.frames;
    final r = _fadeRegion;
    return _toDisplay(
      fadeIn ? _edits.regionFadeIn(r.a, r.b) : _edits.regionFadeOut(r.a, r.b),
    );
  }

  /// Display frame of a handle: where its fade reaches full volume.
  int _handleFrame({required bool fadeIn}) {
    final r = _fadeRegion;
    return fadeIn
        ? r.from + _fadeLength(fadeIn: true)
        : r.to - _fadeLength(fadeIn: false);
  }

  /// Which handle (if any) is under [p] in a waveform [width] wide. The
  /// handles are squares in the top corners of the fades.
  bool? _handleAt(Offset p, double width) {
    if (_edits.clips.isEmpty || p.dy > _handleSize * 2.5) return null;
    double xOf(int frame) => (frame - _viewStart) / _viewSpan * width;
    final inX = xOf(_handleFrame(fadeIn: true));
    final outX = xOf(_handleFrame(fadeIn: false));
    // Fade in's square sits right of its line, fade out's left of it.
    final dIn = (p.dx - (inX + _handleSize / 2)).abs();
    final dOut = (p.dx - (outX - _handleSize / 2)).abs();
    const reach = _handleSize * 1.5;
    if (dIn > reach && dOut > reach) return null;
    return dIn <= dOut;
  }

  void _dragFade(bool fadeIn, double dx, double width) {
    final r = _fadeRegion;
    final x = _beatSnap((_viewStart + dx / width * _viewSpan).round());
    final frames = (fadeIn ? x - r.from : r.to - x).clamp(0, r.to - r.from);
    setState(() => _fadeDrag = (fadeIn: fadeIn, frames: frames));
  }

  /// Finger up: the dragged length becomes the fade (one undo step).
  void _commitFade() {
    final d = _fadeDrag;
    if (d == null) return;
    final r = _fadeRegion;
    final frames = _toEdit(d.frames).clamp(0, r.b - r.a);
    final next = d.fadeIn
        ? _edits.fadeRegionIn(r.a, r.b, frames)
        : _edits.fadeRegionOut(r.a, r.b, frames);
    setState(() => _fadeDrag = null);
    if (next.toJsonString() == _edits.toJsonString()) return;
    _apply(
      d.fadeIn ? 'Fade in' : 'Fade out',
      next,
      position: _toEdit(_position).clamp(0, next.length),
      select: _hasFadeSelection ? (start: r.a, end: r.b) : null,
    );
  }

  void _clearFades() {
    final r = _toolRange;
    _toolDone('Remove fades', _edits.clearFades(r.a, r.b), r);
  }

  /// Brings the loudest point of the selection (or take) to −1 dBFS.
  Future<void> _normalize() async {
    final r = _toolRange;
    final before = _edits;
    final active = _active;
    setState(() => _busy = 'Measuring…');
    double peak;
    try {
      peak = await peakOfClips(
        active?.path ?? widget.take.wav.path,
        clipsForRange(before, r.a, r.b, active),
      );
    } on Object catch (e) {
      if (mounted) setState(() => _busy = null);
      _say('Could not measure the level ($e).');
      return;
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    if (!mounted || !identical(before, _edits)) return; // edited meanwhile
    if (peak < 1e-5) {
      _say('Nothing to normalize: it is silent.');
      return;
    }
    final factor = normalizeTarget / peak;
    if ((factor - 1).abs() < 0.001) {
      _say('Already at −1 dB.');
      return;
    }
    _toolDone('Normalize', _edits.scaleGain(r.a, r.b, factor), r);
    final db = 20 * math.log(factor) / math.ln10;
    _say(
      'Normalized to −1 dB (${db >= 0 ? '+' : ''}${db.toStringAsFixed(1)} dB).',
    );
  }

  /// Trims silence at the start and end of the take (below [_silenceDb]).
  void _trimSilence() {
    final p = _peaks;
    if (p == null) return;
    final range = soundRange(p, _edits.length, dbToGain(_silenceDb));
    if (range == null) {
      _say('All of it is below ${_silenceDb.round()} dB.');
      return;
    }
    final a = range.start == 0 ? 0 : _snap(range.start);
    final b = range.end >= _edits.length ? _edits.length : _snap(range.end);
    if (a <= 0 && b >= _edits.length) {
      _say('No silence to trim at the ends.');
      return;
    }
    final pos = (_toEdit(_position) - a).clamp(0, b - a);
    final message =
        'Trimmed ${_fmtSeconds(a)} from the start and '
        '${_fmtSeconds(_edits.length - b)} from the end.';
    _apply('Trim silence', _edits.trim(a, b), position: pos, zoomOut: true);
    _say(message);
  }

  String _fmtSeconds(int editFrames) =>
      '${(editFrames / sampleRate).toStringAsFixed(2)} s';

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Whether what you hear is ready to export (no render pending).
  bool get _canExport =>
      _pending == null && (_edits.tune.isIdentity || _active != null);

  Future<void> _export(Rect? origin) async {
    final fmt = exportFormats[_exportFormat];
    final sel = _snappedSelection;
    final range = sel == null ? null : (start: sel.a, end: sel.b);
    try {
      setState(() => _busy = 'Exporting…');
      final tmp = await getTemporaryDirectory();
      final root = Directory('${tmp.path}/exports');
      if (root.existsSync()) root.deleteSync(recursive: true); // old shares
      final dir = Directory(
        '${root.path}/${DateTime.now().millisecondsSinceEpoch}',
      )..createSync(recursive: true);
      final items = planExport(
        kind: _exportKind,
        edits: _edits,
        render: _active,
        source: _active?.path ?? widget.take.wav.path,
        dir: dir.path,
        base: _exportBase(),
        range: range,
      );
      if (items.isEmpty) throw StateError('nothing to export');
      await runExports(items, fmt.sampleRate, fmt.bits);
      if (!mounted) return;
      setState(() => _busy = null);
      await SharePlus.instance.share(
        ShareParams(
          files: [
            for (final it in items) XFile(it.output, mimeType: 'audio/wav'),
          ],
          sharePositionOrigin: origin,
        ),
      );
    } on Object catch (e) {
      if (mounted) setState(() => _busy = null);
      _say('Export failed ($e).');
    }
  }

  /// File name base: "Pocket Studio 2026-11-14 0912".
  String _exportBase() {
    final c = widget.take.created;
    String two(int v) => v.toString().padLeft(2, '0');
    return 'Pocket Studio ${c.year}-${two(c.month)}-${two(c.day)} '
        '${two(c.hour)}${two(c.minute)}${two(c.second)}';
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
    final fadeDrag = _fadeDrag;
    // Beat grid as heard; the engine's click follows it.
    final vg = _viewGrid;
    if (AudioControl.ownsPlayer(_playerToken)) {
      Metronome.setGrid(vg?.beatFrames ?? 0, vg?.beatsPerBar ?? 4);
      Metronome.follow(_click && vg != null, downbeat: vg?.downbeat ?? 0);
    }
    final gridLines = vg == null
        ? const <({double at, bool bar})>[]
        : [
            for (final l in vg.lines(_viewStart, _viewStart + _viewSpan))
              (at: (l.frame - _viewStart) / _viewSpan, bar: l.bar),
          ];

    double toView(num frame) => (frame - _viewStart) / _viewSpan;
    final joins = <int>[
      for (var i = 1; i < _edits.clips.length; i++)
        _toDisplay(_edits.startOf(i)),
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
            onSelected: (v) => switch (v) {
              'revert' => _revert(),
              'snap' => setState(() => _snapBeats = !_snapBeats),
              'click' => setState(() => _click = !_click),
              'bounce' => _bounceEdited(),
              'export' => _openExportSheet(),
              _ => _deleteTake(),
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                key: const Key('export'),
                value: 'export',
                enabled: _canExport && _busy == null,
                child: const Text('Export samples…'),
              ),
              PopupMenuItem(
                value: 'bounce',
                enabled: _pending == null,
                child: const Text('Bounce to new take'),
              ),
              if (_grid != null) ...[
                CheckedPopupMenuItem(
                  key: const Key('menu-snap'),
                  value: 'snap',
                  checked: _snapBeats,
                  child: const Text('Snap to beats'),
                ),
                CheckedPopupMenuItem(
                  key: const Key('menu-click'),
                  value: 'click',
                  checked: _click,
                  child: const Text('Click with playback'),
                ),
              ],
              PopupMenuItem(
                value: 'revert',
                enabled: !_edits.isWhole(widget.take.frames),
                child: const Text('Revert to original'),
              ),
              // A stack's mix is deleted with its stack, not from here.
              if (!widget.take.isStackMix)
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete take'),
                ),
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
              _tuneRow(theme),
              SizedBox(
                height: 3,
                child: _pending != null
                    ? LinearProgressIndicator(
                        key: const Key('render-progress'),
                        value: _renderProgress,
                      )
                    : null,
              ),
              const SizedBox(height: 4),
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
                            return Listener(
                              onPointerDown: (e) => _downAt = e.localPosition,
                              child: GestureDetector(
                                key: const Key('waveform'),
                                behavior: HitTestBehavior.opaque,
                                onTapUp: (d) {
                                  // A tap on a fade handle isn't a seek.
                                  if (_handleAt(d.localPosition, w) != null) {
                                    return;
                                  }
                                  PocketAudio.seek(
                                    _frameAt(d.localPosition.dx, w),
                                  );
                                  _tick();
                                },
                                onScaleStart: (d) => _onScaleStart(d, w),
                                onScaleUpdate: (d) => _onScaleUpdate(d, w),
                                onScaleEnd: _onScaleEnd,
                                onLongPressStart: (d) =>
                                    _onLongPressStart(d, w),
                                onLongPressMoveUpdate: (d) =>
                                    _onLongPressMove(d, w),
                                onLongPressEnd: (_) => _onLongPressEnd(),
                                child: ClipRect(
                                  child: CustomPaint(
                                    painter: WaveformPainter(
                                      minMax: peaks.minMax,
                                      // Peaks are in edit frames.
                                      firstBlock: (_viewStart * _tempo / bf)
                                          .floor(),
                                      blockCount: (_viewSpan * _tempo / bf)
                                          .ceil(),
                                      color: scheme.primary,
                                      playhead: playhead >= 0 && playhead <= 1
                                          ? playhead
                                          : null,
                                      playheadColor: _scrubbing
                                          ? scheme.tertiary
                                          : scheme.onSurface,
                                      markers: [
                                        for (final j in joins) toView(j),
                                      ],
                                      markerColor: scheme.secondary,
                                      fades: _edits.clips.isEmpty
                                          ? null
                                          : (
                                              from: toView(_fadeRegion.from),
                                              inEnd: toView(
                                                _handleFrame(fadeIn: true),
                                              ),
                                              outStart: toView(
                                                _handleFrame(fadeIn: false),
                                              ),
                                              to: toView(_fadeRegion.to),
                                              active: fadeDrag?.fadeIn,
                                            ),
                                      fadeColor: scheme.tertiary,
                                      handleSize: _handleSize,
                                      gridLines: gridLines,
                                      gridColor: scheme.onSurface,
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
                child: fadeDrag != null
                    ? _fadeLabel(theme, fadeDrag)
                    : hasSelection
                    ? _selectionBar(theme)
                    : Center(
                        child: Text(
                          _scrubbing
                              ? 'Scrubbing'
                              : 'Drag to scrub · long-press + drag to select '
                                    '· pinch to zoom · drag a top corner '
                                    'to fade',
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
                  const SizedBox(width: 16),
                  IconButton.outlined(
                    key: const Key('tools'),
                    tooltip: 'Sample tools',
                    onPressed: _error == null && _busy == null
                        ? _openToolsSheet
                        : null,
                    icon: const Icon(Icons.auto_fix_high),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- pitch & tempo (M4) ----

  static String _pitchLabel(Tune t) {
    final whole = t.semitones.round();
    final cents = ((t.semitones - whole) * 100).round();
    if (whole == 0 && cents == 0) return 'Pitch';
    final st = whole == 0 ? '' : '${whole > 0 ? '+' : ''}$whole st';
    final c = cents == 0 ? '' : '${cents > 0 ? '+' : ''}$cents¢';
    return [st, c].where((s) => s.isNotEmpty).join(' ');
  }

  static String _tempoLabel(Tune t) =>
      t.tempo == 1 ? 'Tempo' : '${(t.tempo * 100).round()}%';

  static String _signed(num v) => '${v > 0 ? '+' : ''}${v.round()}';

  static String _variLabel(Tune t) => t.varispeed == 0
      ? 'Vari'
      : '${_signed(t.varispeed)} st ×${t.speed.toStringAsFixed(2)}';

  Widget _tuneRow(ThemeData theme) {
    final t = _edits.tune;
    final status =
        _busy ??
        _renderError ??
        (_pending != null
            ? 'Rendering… ${(_renderProgress * 100).round()}%'
            : _active != null || t.isIdentity
            ? _lastRender
            : 'Waiting…');
    return Row(
      children: [
        ActionChip(
          key: const Key('pitch'),
          avatar: const Icon(Icons.music_note, size: 18),
          label: Text(_pitchLabel(t)),
          onPressed: _openTuneSheet,
        ),
        const SizedBox(width: 8),
        ActionChip(
          key: const Key('tempo'),
          avatar: const Icon(Icons.speed, size: 18),
          label: Text(_tempoLabel(t)),
          onPressed: _openTuneSheet,
        ),
        const SizedBox(width: 8),
        ActionChip(
          key: const Key('varispeed'),
          avatar: const Icon(Icons.album, size: 18),
          label: Text(_variLabel(t)),
          onPressed: _openTuneSheet,
        ),
        const SizedBox(width: 8),
        ActionChip(
          key: const Key('bpm'),
          avatar: const Icon(Icons.grid_on, size: 18),
          label: Text(_viewGrid == null ? 'BPM' : _viewGrid!.bpmLabel),
          onPressed: _openGridSheet,
        ),
        const SizedBox(width: 12),
        if (status != null)
          Expanded(
            child: Text(
              status,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _renderError != null ? theme.colorScheme.error : null,
              ),
            ),
          ),
      ],
    );
  }

  /// Sets the take's beat grid: BPM (of the recording), signature, and
  /// optionally the downbeat at the playhead. Undoable.
  Future<void> _openGridSheet() async {
    final g = _grid;
    final heard = _viewGrid;
    final c = await showTempoSheet(
      context,
      initial: g ?? widget.store.tempo.grid(),
      title: 'Beat grid',
      subtitle: heard != null && _tempo != 1
          ? 'BPM of the recording; with tempo/varispeed you hear '
                '${heard.bpmLabel} BPM.'
          : 'Snap edits to beats, see bars, and play a click.',
      downbeatAtPlayhead: true,
      removable: g != null,
      // Detect from the selection if there is one, else the whole take.
      onDetect: (current) {
        final sel = _snappedSelection;
        return detectTakeTempo(
          source: widget.take.wav.path,
          edits: _edits,
          a: sel?.a,
          b: sel?.b,
          beatsPerBar: current.beatsPerBar,
          beatUnit: current.beatUnit,
        );
      },
    );
    if (c == null || !mounted) return;
    var next = c.grid;
    if (next != null && c.downbeatAtPlayhead) {
      next = next.copyWith(downbeat: _toEdit(_position).toDouble());
    }
    if (next != null) widget.store.tempo = widget.store.tempo.withGrid(next);
    _apply(
      next == null ? 'Remove tempo' : 'Set tempo',
      _edits.withGrid(next),
      position: _toEdit(_position),
      select: _selStart == null
          ? null
          : (start: _toEdit(_selStart!), end: _toEdit(_selEnd!)),
    );
  }

  /// Tempo that makes the take play at [bpm] (with the varispeed kept).
  Future<void> _matchBpm(Tune t, void Function(Tune) set) async {
    final g = _grid;
    if (g == null) return;
    final c = TextEditingController(text: g.scaled(t.timeRatio).bpmLabel);
    final bpm = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Play at BPM'),
        content: TextField(
          key: const Key('match-bpm-field'),
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
    if (bpm == null || bpm <= 0 || !mounted) return;
    final tempo = bpm / (g.bpm * t.speed);
    if (tempo < Tune.minTempo - 1e-9 || tempo > Tune.maxTempo + 1e-9) {
      _say(
        '${bpm.toStringAsFixed(1)} BPM needs ${(tempo * 100).round()}% '
        'tempo; the range is 75–150%.',
      );
      return;
    }
    set(t.copyWith(tempo: tempo));
  }

  /// Pitch & tempo controls. Changes apply live: playback continues on the
  /// current audio and switches when the render is ready.
  void _openTuneSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          final t = _edits.tune;
          final whole = t.semitones.round();
          final cents = ((t.semitones - whole) * 100).round();
          void set(Tune next, String label) {
            _setTune(next, label);
            setSheet(() {});
          }

          final theme = Theme.of(context);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Pitch', style: theme.textTheme.titleMedium),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton.filledTonal(
                        key: const Key('pitch-down'),
                        tooltip: 'Down a semitone',
                        onPressed: whole > Tune.minSemitones
                            ? () => set(
                                t.copyWith(
                                  semitones: (whole - 1) + cents / 100,
                                ),
                                'Pitch',
                              )
                            : null,
                        icon: const Icon(Icons.remove),
                      ),
                      SizedBox(
                        width: 120,
                        child: Text(
                          '${whole > 0 ? '+' : ''}$whole st',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      IconButton.filledTonal(
                        key: const Key('pitch-up'),
                        tooltip: 'Up a semitone',
                        onPressed: whole < Tune.maxSemitones
                            ? () => set(
                                t.copyWith(
                                  semitones: (whole + 1) + cents / 100,
                                ),
                                'Pitch',
                              )
                            : null,
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      SizedBox(
                        width: 64,
                        child: Text('${cents > 0 ? '+' : ''}$cents¢'),
                      ),
                      Expanded(
                        child: Slider(
                          key: const Key('cents'),
                          value: cents.toDouble(),
                          min: -50,
                          max: 50,
                          divisions: 100,
                          label: '$cents¢',
                          onChanged: (v) => set(
                            t.copyWith(semitones: whole + v.round() / 100),
                            'Pitch',
                          ),
                        ),
                      ),
                    ],
                  ),
                  SwitchListTile(
                    key: const Key('formant'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Keep voice natural'),
                    subtitle: const Text(
                      'Preserves formants under pitch and varispeed. For '
                      'voice; leave off for instruments and noise.',
                    ),
                    value: t.formant,
                    onChanged: (v) => set(t.copyWith(formant: v), 'Formant'),
                  ),
                  const SizedBox(height: 8),
                  Text('Tempo', style: theme.textTheme.titleMedium),
                  Row(
                    children: [
                      SizedBox(
                        width: 64,
                        child: Text('${(t.tempo * 100).round()}%'),
                      ),
                      Expanded(
                        child: Slider(
                          key: const Key('tempo-slider'),
                          value: t.tempo * 100,
                          min: Tune.minTempo * 100,
                          max: Tune.maxTempo * 100,
                          divisions: 75,
                          label: '${(t.tempo * 100).round()}%',
                          onChanged: (v) =>
                              set(t.copyWith(tempo: v.round() / 100), 'Tempo'),
                        ),
                      ),
                    ],
                  ),
                  if (_grid != null)
                    Row(
                      children: [
                        Text(
                          '= ${_grid!.scaled(t.timeRatio).bpmLabel} BPM',
                          key: const Key('tempo-bpm'),
                        ),
                        const Spacer(),
                        TextButton(
                          key: const Key('match-bpm'),
                          onPressed: () => _matchBpm(t, (n) => set(n, 'Tempo')),
                          child: const Text('Play at BPM…'),
                        ),
                      ],
                    ),
                  const SizedBox(height: 8),
                  Text('Varispeed', style: theme.textTheme.titleMedium),
                  Text(
                    'Like tape: pitch and speed change together.',
                    style: theme.textTheme.bodySmall,
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton.filledTonal(
                        key: const Key('vari-down'),
                        tooltip: 'Slower and lower',
                        onPressed: t.varispeed > Tune.minVarispeed
                            ? () => set(
                                t.copyWith(varispeed: t.varispeed - 1),
                                'Varispeed',
                              )
                            : null,
                        icon: const Icon(Icons.remove),
                      ),
                      SizedBox(
                        width: 160,
                        child: Text(
                          '${_signed(t.varispeed)} st  ×${t.speed.toStringAsFixed(2)}',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      IconButton.filledTonal(
                        key: const Key('vari-up'),
                        tooltip: 'Faster and higher',
                        onPressed: t.varispeed < Tune.maxVarispeed
                            ? () => set(
                                t.copyWith(varispeed: t.varispeed + 1),
                                'Varispeed',
                              )
                            : null,
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _renderError ??
                              (_pending != null
                                  ? 'Rendering… playback switches when ready'
                                  : t.isIdentity
                                  ? 'Original pitch and tempo'
                                  : 'Ready'),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      TextButton(
                        onPressed: t == Tune.none
                            ? null
                            : () => set(
                                Tune.none,
                                'Reset pitch, tempo & varispeed',
                              ),
                        child: const Text('Reset'),
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

  /// Reverse, fades, normalize, trim silence — on the selection, or the
  /// whole take without one.
  void _openToolsSheet() {
    final r = _toolRange;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          final theme = Theme.of(context);
          void run(VoidCallback f) {
            Navigator.pop(context);
            f();
          }

          final scope = r.whole
              ? 'Whole take'
              : 'Selection ${_fmtPrecise(_toDisplay(r.a))} – '
                    '${_fmtPrecise(_toDisplay(r.b))}';
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Sample tools', style: theme.textTheme.titleMedium),
                  Text(scope, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  ListTile(
                    key: const Key('tool-reverse'),
                    leading: const Icon(Icons.swap_horiz),
                    title: const Text('Reverse'),
                    onTap: () => run(_reverse),
                  ),
                  if (_edits.hasFadeOver(r.a, r.b))
                    ListTile(
                      key: const Key('tool-clear-fades'),
                      leading: const Icon(Icons.horizontal_rule),
                      title: const Text('Remove fades'),
                      onTap: () => run(_clearFades),
                    ),
                  ListTile(
                    key: const Key('tool-normalize'),
                    leading: const Icon(Icons.vertical_align_top),
                    title: const Text('Normalize'),
                    subtitle: const Text('Loudest point to −1 dB'),
                    onTap: () => run(_normalize),
                  ),
                  ListTile(
                    key: const Key('tool-trim-silence'),
                    leading: const Icon(Icons.compress),
                    title: const Text('Trim silence'),
                    subtitle: Text(
                      'Start and end of the take, below '
                      '${_silenceDb.round()} dB',
                    ),
                    onTap: () => run(_trimSilence),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: SegmentedButton<double>(
                      key: const Key('silence-threshold'),
                      segments: const [
                        ButtonSegment(value: -60, label: Text('−60 dB')),
                        ButtonSegment(value: -48, label: Text('−48 dB')),
                        ButtonSegment(value: -36, label: Text('−36 dB')),
                      ],
                      selected: {_silenceDb},
                      onSelectionChanged: (v) {
                        setState(() => _silenceDb = v.single);
                        setSheet(() {});
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// One-shot / loop / slices, format, then the share sheet.
  void _openExportSheet() {
    final hasSel = _snappedSelection != null;
    if (_exportKind == ExportKind.slices && _edits.clips.length < 2) {
      _exportKind = ExportKind.oneShot;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          final theme = Theme.of(context);
          final what = switch (_exportKind) {
            ExportKind.oneShot =>
              hasSel
                  ? 'The selection as one file.'
                  : 'The whole take as one file.',
            ExportKind.loop =>
              '${hasSel ? 'The selection' : 'The whole take'} as a seamless '
                  'loop, marked for samplers to loop.',
            ExportKind.slices =>
              'One file per clip (your split points)'
                  '${hasSel ? ' within the selection' : ''}.',
          };
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Export samples', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  SegmentedButton<ExportKind>(
                    key: const Key('export-kind'),
                    segments: [
                      const ButtonSegment(
                        value: ExportKind.oneShot,
                        label: Text('One-shot'),
                      ),
                      const ButtonSegment(
                        value: ExportKind.loop,
                        label: Text('Loop'),
                      ),
                      ButtonSegment(
                        value: ExportKind.slices,
                        label: const Text('Slices'),
                        enabled: _edits.clips.length > 1,
                      ),
                    ],
                    selected: {_exportKind},
                    onSelectionChanged: (v) {
                      setState(() => _exportKind = v.single);
                      setSheet(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(what, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 16),
                  Text('Format', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  RadioGroup<int>(
                    groupValue: _exportFormat,
                    onChanged: (v) {
                      setState(() => _exportFormat = v ?? 0);
                      setSheet(() {});
                    },
                    child: Column(
                      children: [
                        for (var i = 0; i < exportFormats.length; i++)
                          RadioListTile<int>(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: i,
                            title: Text(exportFormats[i].label),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Builder(
                    builder: (context) => FilledButton.icon(
                      key: const Key('export-share'),
                      icon: const Icon(Icons.ios_share),
                      label: const Text('Export & share'),
                      onPressed: () {
                        final box = context.findRenderObject() as RenderBox?;
                        final origin = box == null
                            ? null
                            : box.localToGlobal(Offset.zero) & box.size;
                        Navigator.pop(context);
                        _export(origin);
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
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
              box.maxWidth * clips[i].length / math.max(1, _edits.length) - 4,
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
                    // ⇄ marks a reversed clip.
                    '${i + 1}${clips[i].reverse ? ' ⇄' : ''}',
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

  /// While a fade handle is dragged: its length.
  Widget _fadeLabel(ThemeData theme, ({bool fadeIn, int frames}) d) {
    final secs = d.frames / sampleRate;
    return Center(
      key: const Key('fade-label'),
      child: Text(
        '${d.fadeIn ? 'Fade in' : 'Fade out'} · '
        '${secs.toStringAsFixed(2)} s'
        '${d.frames == 0 ? ' (none)' : ''}',
        style: theme.textTheme.bodyMedium?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
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
