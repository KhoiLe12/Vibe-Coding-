// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// Record screen (wiki/features/record.md): live waveform, level meter with
// clip light, input gain, record / pause / stop. Audio never passes through
// Dart: the C++ recorder writes the file; this screen only polls for display.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pocket_audio/pocket_audio.dart';

import '../audio/audio_control.dart';
import '../takes/take_store.dart';
import '../widgets/waveform.dart';
import 'take_screen.dart';

enum _Phase { starting, noMic, ready, recording, saving }

class RecordScreen extends StatefulWidget {
  const RecordScreen({super.key, required this.store});

  final TakeStore store;

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  static const _windowSeconds = 8;

  _Phase _phase = _Phase.starting;
  String? _error;
  Timer? _ticker;
  late final AppLifecycleListener _lifecycle;

  double _gainDb = 0;
  double _meter = 0; // displayed peak, with decay
  bool _clipped = false;

  ({String id, String wav, String peaks})? _take;
  Float32List _peaks = Float32List(1 << 16);
  int _peakBlocks = 0;
  int _revision = 0;
  int _interruptionsAtStart = 0;
  // Set once the take screen owns the engine; dispose() then leaves it alone
  // (the old route is disposed after the new one has started).
  bool _handedOff = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onHide: _onHide, onShow: _onShow);
    _open();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _ticker?.cancel();
    if (PocketAudio.isRecording) {
      PocketAudio.endRecording(peaksPath: _take?.peaks);
      AudioControl.setRecordingService(false);
    }
    if (!_handedOff) AudioControl.release();
    super.dispose();
  }

  Future<void> _open() async {
    final mic = await AudioControl.ensureMic();
    if (!mounted) return;
    if (mic != MicPermission.granted) {
      setState(() => _phase = _Phase.noMic);
      return;
    }
    try {
      AudioControl.useInput();
      PocketAudio.inputGain = _dbToLinear(_gainDb);
      PocketAudio.resetClip();
      _ticker = Timer.periodic(
        const Duration(milliseconds: 33),
        (_) => _tick(),
      );
      setState(() => _phase = _Phase.ready);
    } on PocketAudioException catch (e) {
      setState(() {
        _phase = _Phase.ready;
        _error = 'Could not open the microphone (${e.message}).';
      });
    }
  }

  // Not recording: close the mic while the app is hidden, so the OS
  // recording indicator turns off. Recording: keep going (background mode).
  void _onHide() {
    if (_phase == _Phase.ready) AudioControl.release();
  }

  void _onShow() {
    if (_phase == _Phase.ready && !PocketAudio.isRunning) {
      try {
        AudioControl.useInput();
      } on PocketAudioException catch (e) {
        setState(
          () => _error = 'Could not reopen the microphone (${e.message}).',
        );
      }
    }
  }

  void _tick() {
    final level = PocketAudio.takeInputPeak();
    var changed = false;
    final shown = math.max(level, _meter * 0.85);
    if ((shown - _meter).abs() > 1e-4) {
      _meter = shown;
      changed = true;
    }
    final clipped = PocketAudio.clipped;
    if (clipped != _clipped) {
      _clipped = clipped;
      changed = true;
    }
    if (_phase == _Phase.recording) {
      _pullPeaks();
      if (PocketAudio.writeError) {
        _stop(
          error:
              'Storage error or the take reached its size limit. '
              'Everything up to now is saved.',
        );
        return;
      }
      changed = true; // elapsed time
    }
    if (changed && mounted) setState(() {});
  }

  void _pullPeaks() {
    final total = PocketAudio.livePeakBlockCount;
    if (total <= _peakBlocks) return;
    if (total * 2 > _peaks.length) {
      final bigger = Float32List(math.max(_peaks.length * 2, total * 2 + 4096))
        ..setAll(0, _peaks);
      _peaks = bigger;
    }
    final fresh = PocketAudio.copyLivePeaks(_peakBlocks, total - _peakBlocks);
    _peaks.setAll(_peakBlocks * 2, fresh);
    _peakBlocks += fresh.length ~/ 2;
    _revision++;
  }

  Future<void> _record() async {
    final take = widget.store.newTake();
    try {
      PocketAudio.beginRecording(take.wav, sampleRate: sampleRate);
    } on PocketAudioException catch (e) {
      setState(() => _error = 'Could not start recording (${e.message}).');
      return;
    }
    await AudioControl.setRecordingService(true);
    setState(() {
      _take = take;
      _peakBlocks = 0;
      _revision++;
      _error = null;
      _interruptionsAtStart = PocketAudio.interruptionCount;
      _phase = _Phase.recording;
    });
  }

  void _togglePause() {
    setState(() => PocketAudio.paused = !PocketAudio.isPaused);
  }

  Future<void> _stop({String? error}) async {
    if (_phase != _Phase.recording) return;
    final take = _take!;
    final stopwatch = Stopwatch()..start();
    setState(() => _phase = _Phase.saving);
    try {
      PocketAudio.endRecording(peaksPath: take.peaks);
    } on PocketAudioException catch (e) {
      error ??= 'The take may be incomplete (${e.message}).';
    }
    await AudioControl.setRecordingService(false);
    _ticker?.cancel();
    AudioControl.release();
    if (!mounted) return;
    final saved = widget.store.list().where((t) => t.id == take.id);
    if (saved.isEmpty) {
      setState(() {
        _phase = _Phase.ready;
        _error = error ?? 'Nothing was recorded.';
      });
      _open();
      return;
    }
    _handedOff = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => TakeScreen(
          store: widget.store,
          take: saved.first,
          sinceStop: stopwatch,
          message: error,
        ),
      ),
    );
  }

  static double _dbToLinear(double db) => math.pow(10, db / 20).toDouble();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recording = _phase == _Phase.recording;
    final paused = recording && PocketAudio.isPaused;
    final written = recording ? PocketAudio.framesWritten : 0;
    final dropped = recording ? PocketAudio.droppedFrames : 0;
    final interrupted =
        recording && PocketAudio.interruptionCount > _interruptionsAtStart;
    final windowBlocks =
        _windowSeconds * sampleRate ~/ PocketAudio.peakBlockFrames;
    final first = math.max(0, _peakBlocks - windowBlocks);

    return PopScope(
      canPop: !recording && _phase != _Phase.saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && recording) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Stop the recording first — it will be saved.'),
            ),
          );
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Record')),
        body: SafeArea(
          child: _phase == _Phase.noMic
              ? _NoMic(
                  onRetry: () {
                    setState(() => _phase = _Phase.starting);
                    _open();
                  },
                )
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        recording
                            ? formatDuration(
                                Duration(
                                  milliseconds: written * 1000 ~/ sampleRate,
                                ),
                              )
                            : '00:00',
                        key: const Key('elapsed'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.displayMedium?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: recording && !paused
                              ? theme.colorScheme.error
                              : null,
                        ),
                      ),
                      Text(
                        paused
                            ? 'Paused — resume to continue the same take'
                            : recording
                            ? 'Recording'
                            : _phase == _Phase.starting
                            ? 'Opening microphone…'
                            : 'Ready',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: ClipRect(
                            child: CustomPaint(
                              painter: WaveformPainter(
                                minMax: _peaks,
                                firstBlock: first,
                                blockCount: windowBlocks,
                                color: theme.colorScheme.primary,
                                revision: _revision,
                              ),
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      LevelMeter(
                        peak: _meter,
                        clipped: _clipped,
                        onResetClip: () {
                          PocketAudio.resetClip();
                          setState(() => _clipped = false);
                        },
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Text('Gain'),
                          Expanded(
                            child: Slider(
                              key: const Key('gain'),
                              value: _gainDb,
                              min: -12,
                              max: 24,
                              divisions: 36,
                              label:
                                  '${_gainDb >= 0 ? '+' : ''}'
                                  '${_gainDb.round()} dB',
                              onChanged: (v) {
                                setState(() => _gainDb = v);
                                PocketAudio.inputGain = _dbToLinear(v);
                              },
                            ),
                          ),
                          SizedBox(
                            width: 56,
                            child: Text(
                              '${_gainDb >= 0 ? '+' : ''}${_gainDb.round()} dB',
                              textAlign: TextAlign.end,
                            ),
                          ),
                        ],
                      ),
                      if (_error != null || dropped > 0 || interrupted)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            _error ??
                                (dropped > 0
                                    ? 'Warning: ${dropped * 1000 ~/ sampleRate} ms '
                                          'of audio was lost (storage too slow).'
                                    : 'Interrupted by the system (call or '
                                          'another app); recording continued '
                                          'afterwards.'),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox.square(
                            dimension: 64,
                            child: recording
                                ? IconButton.filledTonal(
                                    key: const Key('pause'),
                                    tooltip: paused ? 'Resume' : 'Pause',
                                    onPressed: _togglePause,
                                    icon: Icon(
                                      paused
                                          ? Icons.fiber_manual_record
                                          : Icons.pause,
                                    ),
                                  )
                                : null,
                          ),
                          const SizedBox(width: 24),
                          SizedBox.square(
                            dimension: 96,
                            child: FilledButton(
                              key: const Key('record'),
                              style: FilledButton.styleFrom(
                                shape: const CircleBorder(),
                                backgroundColor: theme.colorScheme.error,
                                foregroundColor: theme.colorScheme.onError,
                              ),
                              onPressed: switch (_phase) {
                                _Phase.ready => _record,
                                _Phase.recording => _stop,
                                _ => null,
                              },
                              child: Icon(
                                recording
                                    ? Icons.stop
                                    : Icons.fiber_manual_record,
                                size: 48,
                              ),
                            ),
                          ),
                          const SizedBox(width: 88),
                        ],
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

class _NoMic extends StatelessWidget {
  const _NoMic({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.mic_off, size: 64),
            const SizedBox(height: 16),
            const Text(
              'Pocket Studio needs the microphone to record.\n'
              'Allow it in Settings › Pocket Studio › Microphone, then try again.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
