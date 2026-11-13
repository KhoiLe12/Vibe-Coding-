// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// One take: waveform, playhead, play/pause, seek (tap/drag the waveform,
// ±5 s buttons). The M1 "editor". Audible scrubbing and the M2 latency
// criteria come later (wiki/features/playback-and-scrub.md).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pocket_audio/pocket_audio.dart';

import '../audio/audio_control.dart';
import '../takes/take_store.dart';
import '../widgets/waveform.dart';

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
  int? _dragFrame; // playhead while the finger is down; seek on release
  bool _seeking = false;
  int? _pendingSeek;

  @override
  void initState() {
    super.initState();
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
                debugPrint(
                  'take shown ${sw.elapsedMilliseconds} ms after stop',
                );
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
    PocketAudio.closeTake();
    AudioControl.release();
    super.dispose();
  }

  void _tick() {
    final playing = PocketAudio.isPlaying;
    final position = PocketAudio.playbackPosition;
    if (_dragFrame != null || _seeking) return;
    if (playing != _playing || position != _position) {
      setState(() {
        _playing = playing;
        _position = position;
      });
    }
  }

  void _toggle() {
    if (PocketAudio.isPlaying) {
      PocketAudio.playing = false;
    } else {
      if (PocketAudio.playbackFinished) PocketAudio.seek(0);
      PocketAudio.playing = true;
    }
    _tick();
  }

  /// Jumps to [frame]. While playing, fades out first (the player fades back
  /// in after the jump), so the cut never clicks.
  Future<void> _seekTo(int frame) async {
    frame = frame.clamp(0, widget.take.frames);
    if (_seeking) {
      _pendingSeek = frame;
      return;
    }
    _seeking = true;
    setState(() => _position = frame);
    final wasPlaying = PocketAudio.isPlaying;
    if (wasPlaying) {
      PocketAudio.playing = false;
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    PocketAudio.seek(frame);
    if (wasPlaying) PocketAudio.playing = true;
    _seeking = false;
    final next = _pendingSeek;
    _pendingSeek = null;
    if (next != null) return _seekTo(next);
    _tick();
  }

  int _frameAt(double dx, double width) =>
      (dx / width * widget.take.frames).round().clamp(0, widget.take.frames);

  void _skip(int seconds) => _seekTo(_position + seconds * sampleRate);

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final length = widget.take.frames;
    final peaks = _peaks;
    final shown = _dragFrame ?? _position;
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
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: peaks == null
                      ? const Center(child: CircularProgressIndicator())
                      : LayoutBuilder(
                          builder: (context, box) => GestureDetector(
                            key: const Key('waveform'),
                            behavior: HitTestBehavior.opaque,
                            onTapUp: (d) => _seekTo(
                              _frameAt(d.localPosition.dx, box.maxWidth),
                            ),
                            onHorizontalDragStart: (d) => setState(
                              () => _dragFrame = _frameAt(
                                d.localPosition.dx,
                                box.maxWidth,
                              ),
                            ),
                            onHorizontalDragUpdate: (d) => setState(
                              () => _dragFrame = _frameAt(
                                d.localPosition.dx,
                                box.maxWidth,
                              ),
                            ),
                            onHorizontalDragEnd: (_) {
                              final f = _dragFrame;
                              _dragFrame = null;
                              if (f != null) _seekTo(f);
                            },
                            onHorizontalDragCancel: () =>
                                setState(() => _dragFrame = null),
                            child: ClipRect(
                              child: CustomPaint(
                                painter: WaveformPainter(
                                  minMax: peaks.minMax,
                                  firstBlock: 0,
                                  blockCount: peaks.blocks,
                                  color: theme.colorScheme.primary,
                                  playhead: length == 0 ? 0 : shown / length,
                                  playheadColor: theme.colorScheme.onSurface,
                                ),
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '${formatDuration(Duration(milliseconds: shown * 1000 ~/ sampleRate))}'
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
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton.filledTonal(
                    key: const Key('back5'),
                    tooltip: 'Back 5 s',
                    iconSize: 32,
                    onPressed: _error == null ? () => _skip(-5) : null,
                    icon: const Icon(Icons.replay_5),
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
                  IconButton.filledTonal(
                    key: const Key('fwd5'),
                    tooltip: 'Forward 5 s',
                    iconSize: 32,
                    onPressed: _error == null ? () => _skip(5) : null,
                    icon: const Icon(Icons.forward_5),
                  ),
                ],
              ),
            ],
          ),
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
