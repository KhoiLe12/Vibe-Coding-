// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// One take (wiki/features/playback-and-scrub.md):
// - one finger drag: tape-style scrub, relative to the playhead, speed capped
//   independent of zoom (wiki/decisions/d009-scrub-style.md)
// - tap: jump there
// - long-press + drag: select a loop region (plays seamlessly)
// - two fingers: pinch to zoom, drag to pan; overview strip shows where you are
// - ⏪5 / 5⏩: tap to jump 5 s, hold to rewind / fast-forward at 4×

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocket_audio/pocket_audio.dart';

import '../audio/audio_control.dart';
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
  Peaks? _peaks;
  String? _error;
  int? _openedMs;
  Timer? _ticker;
  bool _playing = false;
  int _position = 0;

  // Visible window, in frames.
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

  // Loop selection (frames), and whether the loop is on.
  int? _selStart, _selEnd;
  bool _loopOn = false;

  int get _length => widget.take.frames;

  @override
  void initState() {
    super.initState();
    _viewSpan = math.max(1, _length).toDouble();
    try {
      AudioControl.useOutput();
      PocketAudio.openTake(widget.take.wav.path);
    } on PocketAudioException catch (e) {
      _error = 'Could not open this take for playback (${e.message}).';
    }
    widget.store
        .loadPeaks(widget.take)
        .then(
          (p) {
            if (!mounted) return;
            setState(() => _peaks = p);
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
    final minSpan = _minViewSeconds * sampleRate;
    span = span.clamp(
      math.min(minSpan, _length.toDouble()),
      _length.toDouble(),
    );
    _viewSpan = span;
    _viewStart = start.clamp(0.0, math.max(0.0, _length - span));
  }

  int _frameAt(double dx, double width) =>
      (_viewStart + dx / width * _viewSpan).round().clamp(0, _length);

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

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this take?'),
        content: Text(
          '${formatDuration(widget.take.duration)} of audio will '
          'be deleted from this phone. This cannot be undone.',
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

    double toView(num frame) => (frame - _viewStart) / _viewSpan;

    return Scaffold(
      appBar: AppBar(
        title: Text(takeTitle(widget.take)),
        actions: [
          IconButton(
            tooltip: 'Delete take',
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
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
                // Overview: the whole take, with the visible window shaded.
                SizedBox(
                  height: 36,
                  child: LayoutBuilder(
                    builder: (context, box) {
                      void centre(double dx) => setState(() {
                        final f = dx / box.maxWidth * _length;
                        _setView(f - _viewSpan / 2, _viewSpan);
                      });
                      return GestureDetector(
                        key: const Key('overview'),
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (d) => centre(d.localPosition.dx),
                        onHorizontalDragUpdate: (d) =>
                            centre(d.localPosition.dx),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: ColoredBox(
                            color: scheme.surfaceContainerHighest.withValues(
                              alpha: 0.5,
                            ),
                            child: CustomPaint(
                              painter: WaveformPainter(
                                minMax: peaks.minMax,
                                firstBlock: 0,
                                blockCount: peaks.blocks,
                                color: scheme.primary.withValues(alpha: 0.7),
                                playhead: _length == 0
                                    ? 0
                                    : _position / _length,
                                playheadColor: scheme.onSurface,
                                bands: [
                                  if (_viewSpan < _length)
                                    (
                                      from: _viewStart / _length,
                                      to: (_viewStart + _viewSpan) / _length,
                                      color: scheme.primary.withValues(
                                        alpha: 0.2,
                                      ),
                                    ),
                                  if (_selStart != null)
                                    (
                                      from: _selStart! / _length,
                                      to: _selEnd! / _length,
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
              const SizedBox(height: 8),
              if (_selStart != null && _selAnchor == null)
                Row(
                  children: [
                    const Icon(Icons.repeat, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Loop ${_fmtPrecise(_selStart!)} – '
                        '${_fmtPrecise(_selEnd!)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    Switch(
                      key: const Key('loop'),
                      value: _loopOn,
                      onChanged: _setLoopOn,
                    ),
                    IconButton(
                      tooltip: 'Clear selection',
                      onPressed: _clearSelection,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                )
              else
                Text(
                  _scrubbing
                      ? 'Scrubbing'
                      : 'Drag to scrub · long-press + drag to loop · '
                            'pinch to zoom',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              const SizedBox(height: 4),
              Text(
                '${formatDuration(Duration(milliseconds: _position * 1000 ~/ sampleRate))}'
                ' / ${formatDuration(widget.take.duration)}',
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
                  _HoldButton(
                    key: const Key('back5'),
                    icon: Icons.replay_5,
                    label: 'Back 5 seconds; hold to rewind',
                    enabled: _error == null,
                    onTap: () => _skip(-5),
                    onHoldStart: () => _shuttle(-_shuttleSpeed),
                    onHoldEnd: _endShuttle,
                  ),
                  const SizedBox(width: 24),
                  SizedBox.square(
                    dimension: 96,
                    child: FilledButton(
                      key: const Key('play'),
                      style: FilledButton.styleFrom(
                        shape: const CircleBorder(),
                      ),
                      onPressed: _error == null ? _toggle : null,
                      child: Icon(
                        _playing ? Icons.pause : Icons.play_arrow,
                        size: 56,
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  _HoldButton(
                    key: const Key('fwd5'),
                    icon: Icons.forward_5,
                    label: 'Forward 5 seconds; hold to fast-forward',
                    enabled: _error == null,
                    onTap: () => _skip(5),
                    onHoldStart: () => _shuttle(_shuttleSpeed),
                    onHoldEnd: _endShuttle,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
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
