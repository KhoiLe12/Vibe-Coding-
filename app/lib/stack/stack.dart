// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
//
// A stack of layers (M6, wiki/features/layers.md, wiki/decisions/
// d015-layers.md): takes played together, each at an offset. Immutable, so
// every change is a snapshot for undo (History<LayerStack>, d012). Offsets are
// frames on the stack's timeline, never below 0. Layers stay where they are
// put — silence at the start is allowed (human, 2026-11-14: re-aligning the
// earliest layer to 0 made lining up annoying).

import 'dart:convert';

import '../tempo/grid.dart';

class Layer {
  const Layer(
    this.takeId, {
    this.offset = 0,
    this.volume = 1,
    this.muted = false,
    this.solo = false,
  });

  final String takeId;
  final int offset;
  final double volume;
  final bool muted;
  final bool solo;

  Layer copyWith({int? offset, double? volume, bool? muted, bool? solo}) =>
      Layer(
        takeId,
        offset: offset ?? this.offset,
        volume: volume ?? this.volume,
        muted: muted ?? this.muted,
        solo: solo ?? this.solo,
      );

  Map<String, Object> toJson() => {
    'take': takeId,
    'offset': offset,
    'volume': volume,
    'muted': muted,
    'solo': solo,
  };

  static Layer fromJson(Map<String, dynamic> j) => Layer(
    j['take'] as String,
    offset: j['offset'] as int? ?? 0,
    volume: (j['volume'] as num?)?.toDouble() ?? 1,
    muted: j['muted'] as bool? ?? false,
    solo: j['solo'] as bool? ?? false,
  );

  @override
  bool operator ==(Object other) =>
      other is Layer &&
      other.takeId == takeId &&
      other.offset == offset &&
      other.volume == volume &&
      other.muted == muted &&
      other.solo == solo;

  @override
  int get hashCode => Object.hash(takeId, offset, volume, muted, solo);
}

class LayerStack {
  LayerStack(this.id, this.created, List<Layer> layers, {this.grid})
    : layers = List.unmodifiable(_clamped(layers));

  /// Beat grid on the stack's timeline (M5b, d017), or null.
  final Grid? grid;

  LayerStack withGrid(Grid? g) => LayerStack(id, created, layers, grid: g);

  final String id;
  final DateTime created;
  final List<Layer> layers;

  static const maxLayers = 16; // the engine's track limit

  /// A layer slid before the start stops at 0; nothing else moves.
  static List<Layer> _clamped(List<Layer> layers) => [
    for (final l in layers) l.offset < 0 ? l.copyWith(offset: 0) : l,
  ];

  LayerStack _with(List<Layer> next) =>
      LayerStack(id, created, next, grid: grid);

  bool get full => layers.length >= maxLayers;

  LayerStack add(Layer l) => full ? this : _with([...layers, l]);
  LayerStack remove(int i) => _with([...layers]..removeAt(i));
  LayerStack replace(int i, Layer l) => _with([...layers]..[i] = l);

  /// Effective gain of each layer after mute/solo.
  List<double> get gains {
    final anySolo = layers.any((l) => l.solo);
    return [
      for (final l in layers) l.muted || (anySolo && !l.solo) ? 0.0 : l.volume,
    ];
  }

  bool uses(String takeId) => layers.any((l) => l.takeId == takeId);

  String toJsonString() => jsonEncode({
    'version': 1,
    'created': created.toIso8601String(),
    'layers': [for (final l in layers) l.toJson()],
    if (grid != null) 'grid': grid!.toJson(),
  });

  static LayerStack fromJsonString(String id, String s) {
    final j = jsonDecode(s) as Map<String, dynamic>;
    return LayerStack(
      id,
      DateTime.tryParse(j['created'] as String? ?? '') ?? DateTime.now(),
      [
        for (final l in j['layers'] as List)
          Layer.fromJson(l as Map<String, dynamic>),
      ],
      grid: Grid.fromJson(j['grid'] as Map<String, dynamic>?),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LayerStack &&
      other.id == id &&
      other.grid == grid &&
      other.layers.length == layers.length &&
      Iterable.generate(layers.length)
          .every((i) => other.layers[i] == layers[i]);

  @override
  int get hashCode => Object.hash(id, grid, Object.hashAll(layers));
}
