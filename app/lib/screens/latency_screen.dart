// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// M2 go/no-go gate (wiki/decisions/d008-latency-gate-route.md,
// wiki/concepts/audio-latency.md): measures the round trip speaker → mic with
// chirps, shows the OS-reported figure alongside, and checks for drift over
// 10 minutes. Pass: median ≤ 30 ms and the last minute's median within 1 ms
// of the first minute's.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocket_audio/pocket_audio.dart';

import '../audio/audio_control.dart';

const _targetMs = 30.0;
const _maxDriftMs = 1.0;
const _intervalMs = 500;

enum _Run { idle, quick, full }

class LatencyScreen extends StatefulWidget {
  const LatencyScreen({super.key});

  @override
  State<LatencyScreen> createState() => _LatencyScreenState();
}

class _LatencyScreenState extends State<LatencyScreen> {
  _Run _run = _Run.idle;
  _Run _lastRun = _Run.idle;
  DateTime? _started;
  Duration _length = Duration.zero;
  Timer? _ticker;
  List<double> _ms = const [];
  int _missed = 0;
  bool _overflow = false;
  ({double input, double output, double ioBuffer})? _reported;
  String? _error;
  // Requested I/O buffer frames; 0 = miniaudio's default (10 ms).
  int _period = AudioControl.duplexPeriodFrames;
  ({
    int playbackPeriod,
    int playbackPeriods,
    int capturePeriod,
    int capturePeriods,
    int sampleRate,
  })?
  _buffers;

  @override
  void dispose() {
    _ticker?.cancel();
    PocketAudio.stopLatencyProbe();
    AudioControl.release();
    super.dispose();
  }

  Future<void> _start(_Run run) async {
    final mic = await AudioControl.ensureMic();
    if (!mounted) return;
    if (mic != MicPermission.granted) {
      setState(
        () => _error =
            'The microphone is needed to hear the clicks. '
            'Allow it in Settings › Pocket Studio › Microphone.',
      );
      return;
    }
    try {
      AudioControl.release();
      AudioControl.useInput(periodFrames: _period);
    } on PocketAudioException catch (e) {
      setState(() => _error = 'Could not open audio (${e.message}).');
      return;
    }
    _buffers = PocketAudio.bufferInfo;
    PocketAudio.startLatencyProbe(intervalMs: _intervalMs);
    setState(() {
      _error = null;
      _run = run;
      _lastRun = run;
      _started = DateTime.now();
      _length = run == _Run.quick
          ? const Duration(seconds: 15)
          : const Duration(minutes: 10);
      _ms = const [];
      _missed = 0;
      _reported = PocketAudio.reportedLatency;
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
  }

  void _tick() {
    final n = PocketAudio.latencyCount;
    final fresh = PocketAudio.latencyResults(_ms.length, n - _ms.length);
    setState(() {
      _ms = [..._ms, ...fresh];
      _missed = PocketAudio.latencyMissed;
      _overflow = PocketAudio.latencyInputOverflow;
      _reported = PocketAudio.reportedLatency;
    });
    if (DateTime.now().difference(_started!) >= _length) _stop();
  }

  void _stop() {
    _ticker?.cancel();
    _ticker = null;
    PocketAudio.stopLatencyProbe();
    AudioControl.release();
    // Pick up the last results after the probe stopped.
    final n = PocketAudio.latencyCount;
    final fresh = PocketAudio.latencyResults(_ms.length, n - _ms.length);
    setState(() {
      _ms = [..._ms, ...fresh];
      _missed = PocketAudio.latencyMissed;
      _run = _Run.idle;
    });
  }

  static double _median(List<double> v) {
    if (v.isEmpty) return double.nan;
    final s = [...v]..sort();
    return s.length.isOdd
        ? s[s.length ~/ 2]
        : (s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2;
  }

  /// Per minute: 60 s / 0.5 s = 120 measurements.
  static const _perMinute = 60000 ~/ _intervalMs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = _run != _Run.idle;
    final median = _median(_ms);
    final lo = _ms.isEmpty ? double.nan : _ms.reduce(math.min);
    final hi = _ms.isEmpty ? double.nan : _ms.reduce(math.max);
    final firstMin = _ms.length >= 2 * _perMinute
        ? _median(_ms.sublist(0, _perMinute))
        : null;
    final lastMin = _ms.length >= 2 * _perMinute
        ? _median(_ms.sublist(_ms.length - _perMinute))
        : null;
    final drift = firstMin != null && lastMin != null
        ? lastMin - firstMin
        : null;
    final elapsed = _started == null
        ? Duration.zero
        : DateTime.now().difference(_started!);
    final reported = _reported;
    final reportedMs = reported == null
        ? null
        : (reported.input + reported.output + 2 * reported.ioBuffer) * 1000;

    String fmt(double v) => v.isNaN ? '—' : '${v.toStringAsFixed(1)} ms';

    final fullDone = !running && _lastRun == _Run.full && _ms.isNotEmpty;
    final pass =
        fullDone &&
        median <= _targetMs &&
        drift != null &&
        drift.abs() <= _maxDriftMs &&
        !_overflow;

    return Scaffold(
      appBar: AppBar(title: const Text('Latency test')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Lay the phone on a table in a quiet room and turn the volume '
              'up. Pocket Studio plays a short chirp twice a second through '
              'the speaker and times how long it takes to come back in '
              'through the microphone.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Text(
              fmt(median),
              key: const Key('median'),
              textAlign: TextAlign.center,
              style: theme.textTheme.displayMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                color: median.isNaN
                    ? null
                    : median <= _targetMs
                    ? Colors.green
                    : theme.colorScheme.error,
              ),
            ),
            Text(
              'measured round trip (median) · target ≤ ${_targetMs.toInt()} ms',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            _Row(
              'Measurements',
              '${_ms.length}'
                  '${_missed > 0 ? ' ($_missed not heard)' : ''}',
            ),
            _Row('Lowest / highest', '${fmt(lo)} / ${fmt(hi)}'),
            _Row(
              'Drift (last vs first minute)',
              drift == null
                  ? 'needs 2+ minutes'
                  : '${drift >= 0 ? '+' : ''}${drift.toStringAsFixed(2)} ms',
            ),
            _Row(
              'iOS reports',
              reportedMs == null
                  ? '—'
                  : '${reportedMs.toStringAsFixed(1)} ms '
                        '(in ${(reported!.input * 1000).toStringAsFixed(1)}'
                        ' + out ${(reported.output * 1000).toStringAsFixed(1)}'
                        ' + 2 × buffer '
                        '${(reported.ioBuffer * 1000).toStringAsFixed(1)})',
            ),
            _Row(
              'Buffers granted',
              _buffers == null
                  ? '—'
                  : 'out ${_buffers!.playbackPeriod}×${_buffers!.playbackPeriods}'
                        ', in ${_buffers!.capturePeriod}×${_buffers!.capturePeriods}'
                        ' frames @ ${_buffers!.sampleRate} Hz',
            ),
            const SizedBox(height: 8),
            Text(
              'Buffer size (smaller = lower latency)',
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            SegmentedButton<int>(
              key: const Key('period'),
              segments: const [
                ButtonSegment(value: 0, label: Text('Default')),
                ButtonSegment(value: 512, label: Text('512')),
                ButtonSegment(value: 256, label: Text('256')),
                ButtonSegment(value: 128, label: Text('128')),
                ButtonSegment(value: 64, label: Text('64')),
              ],
              selected: {_period},
              onSelectionChanged: running
                  ? null
                  : (s) => setState(() => _period = s.single),
            ),
            if (running)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(
                  value: (elapsed.inMilliseconds / _length.inMilliseconds)
                      .clamp(0.0, 1.0),
                ),
              ),
            if (_overflow)
              Text(
                'Results unreliable: the analysis fell behind.',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (fullDone)
              Card(
                margin: const EdgeInsets.only(top: 16),
                color: pass ? Colors.green.shade700 : theme.colorScheme.error,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    pass
                        ? 'GATE PASSED: ${fmt(median)}, drift '
                              '${drift.toStringAsFixed(2)} ms over 10 minutes.'
                        : 'GATE NOT PASSED: median ${fmt(median)}, drift '
                              '${drift?.toStringAsFixed(2) ?? '—'} ms '
                              '(need ≤ ${_targetMs.toInt()} ms and '
                              '≤ ${_maxDriftMs.toStringAsFixed(0)} ms drift).',
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
              ),
            const SizedBox(height: 24),
            if (running)
              OutlinedButton(onPressed: _stop, child: const Text('Stop'))
            else ...[
              FilledButton(
                key: const Key('quick'),
                onPressed: () => _start(_Run.quick),
                child: const Text('Quick test (15 s)'),
              ),
              const SizedBox(height: 8),
              FilledButton.tonal(
                key: const Key('full'),
                onPressed: () => _start(_Run.full),
                child: const Text('Full gate test (10 min)'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
