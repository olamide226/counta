import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:counta/ui/widgets/quick_controls_bar.dart';

Widget _wrap({required double width}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: SingleChildScrollView(
            child: QuickControlsBar(
              onReset: () {},
              onUndo: () {},
              onSave: () {},
              onAlertConfig: () {},
              onSoundMode: () {},
              soundModeIcon: Icons.volume_up,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('QuickControlsBar', () {
    testWidgets('does not overflow at the narrow width the info pane can hit',
        (tester) async {
      // 49px is the width reported in the RenderFlex overflow: the five icon
      // buttons needed 272px and ran 223px past the edge.
      await tester.pumpWidget(_wrap(width: 49));
      expect(tester.takeException(), isNull);
    });

    testWidgets('does not overflow across the full range of pane widths',
        (tester) async {
      for (final width in <double>[1, 20, 49, 100, 180, 319, 320, 400, 800]) {
        await tester.pumpWidget(_wrap(width: width));
        expect(
          tester.takeException(),
          isNull,
          reason: 'overflowed at width $width',
        );
      }
    });

    testWidgets('keeps all five controls reachable when narrow', (tester) async {
      await tester.pumpWidget(_wrap(width: 49));

      expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
      expect(find.byIcon(Icons.undo), findsOneWidget);
      expect(find.byIcon(Icons.notifications_active_outlined), findsOneWidget);
      expect(find.byIcon(Icons.volume_up), findsOneWidget);
      expect(find.byIcon(Icons.save_outlined), findsOneWidget);
    });
  });
}
