// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_studio/main.dart';

void main() {
  testWidgets('hello tone screen shows the native core version',
      (tester) async {
    await tester.pumpWidget(const PocketStudioApp());
    expect(find.text('Hello tone'), findsOneWidget);
    // Reading the version calls into the C++ core over FFI.
    expect(find.textContaining('miniaudio 0.11.25'), findsOneWidget);
  });
}
