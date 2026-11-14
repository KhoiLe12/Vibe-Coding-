// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_studio/audio/calibration.dart';

void main() {
  test('round trips are stored per route and survive reloading', () {
    final dir = Directory.systemTemp.createTempSync('ps_cal_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/calibration.json');
    final c = Calibration(f);
    expect(c.framesFor('Speaker'), isNull);
    c.save('Speaker', 1061);
    c.save('Headphones', 400);
    final again = Calibration(f);
    expect(again.framesFor('Speaker'), 1061);
    expect(again.framesFor('Headphones'), 400);
    f.writeAsStringSync('{broken');
    expect(Calibration(f).framesFor('Speaker'), isNull);
  });
}
