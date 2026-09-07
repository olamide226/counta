import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:counta/ui/screens/debug/streaming_debug_screen.dart';

void main() {
  group('StreamingDebugScreen', () {
    testWidgets('does not overflow at the reported viewport height', (
      tester,
    ) async {
      // 388x551 is the body constraint from the RenderFlex overflow: the fixed
      // header (two text fields, the fixture row, controls, latency panel and
      // live-interim strip) was taller than the viewport.
      tester.view.physicalSize = const Size(388, 551);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: StreamingDebugScreen()));

      expect(tester.takeException(), isNull);
    });

    testWidgets('survives a short viewport, as with the keyboard up', (
      tester,
    ) async {
      for (final height in <double>[320, 400, 551, 700, 1000]) {
        tester.view.physicalSize = Size(388, height);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          const MaterialApp(home: StreamingDebugScreen()),
        );

        expect(
          tester.takeException(),
          isNull,
          reason: 'overflowed at viewport height $height',
        );
      }
    });

    testWidgets('header content is reachable by scrolling', (tester) async {
      tester.view.physicalSize = const Size(388, 551);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: StreamingDebugScreen()));

      expect(find.text('Fixture name'), findsOneWidget);

      // The empty-state row sits below the fold at this height, so the page
      // must scroll rather than clip it.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pump();

      expect(find.text('No final transcripts yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
