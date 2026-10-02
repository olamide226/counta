import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/state/providers/voice_minutes_provider.dart';
import 'package:counta/ui/widgets/voice_minutes_widgets.dart';
import 'package:counta/ui/widgets/voice_session_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

  group('what a stop cost, in words', () {
    test('a short session: one used, the rest returned', () {
      final words = describeVoiceUsage(
        const VoiceUsage(used: 1, returned: 4, left: 22),
      );
      expect(words.title, 'Used 1 voice minute');
      expect(words.detail, '4 unused minutes returned. 22 left.');
    });

    test('a single minute returned is singular', () {
      final words = describeVoiceUsage(
        const VoiceUsage(used: 4, returned: 1, left: 9),
      );
      expect(words.title, 'Used 4 voice minutes');
      expect(words.detail, '1 unused minute returned. 9 left.');
    });

    test('nothing returned says nothing about returns', () {
      final words = describeVoiceUsage(
        const VoiceUsage(used: 5, returned: 0, left: 18),
      );
      expect(words.detail, '18 left.');
    });

    test('a session that never got going cost nothing', () {
      final words = describeVoiceUsage(
        const VoiceUsage(used: 0, returned: 5, left: 23),
      );
      expect(words.title, 'No voice minutes used');
    });

    test('an unknown balance is left out rather than guessed', () {
      final words = describeVoiceUsage(const VoiceUsage(used: 5, returned: 0));
      expect(words.detail, isNull);
    });
  });

  group('VoiceUsageStrip', () {
    testWidgets('goes away by itself', (tester) async {
      var dismissed = 0;
      await pump(
        tester,
        VoiceUsageStrip(
          usage: const VoiceUsage(used: 1, returned: 4, left: 22),
          onDismiss: () => dismissed++,
          visibleFor: const Duration(seconds: 10),
        ),
      );
      expect(find.text('Used 1 voice minute'), findsOneWidget);

      await tester.pump(const Duration(seconds: 9));
      expect(dismissed, 0);
      await tester.pump(const Duration(seconds: 2));
      expect(dismissed, 1);
    });

    testWidgets('can be dismissed sooner', (tester) async {
      var dismissed = 0;
      await pump(
        tester,
        VoiceUsageStrip(
          usage: const VoiceUsage(used: 1, returned: 4, left: 22),
          onDismiss: () => dismissed++,
        ),
      );

      await tester.tap(find.byTooltip('Dismiss'));
      expect(dismissed, 1);

      // Unmounting cancels the timer; a pending one would fail the test.
      await pump(tester, const SizedBox());
    });
  });

  group('VoicePausedBanner', () {
    testWidgets('says what stopped, that the count is safe, and what next', (
      tester,
    ) async {
      var getMinutes = 0;
      var dismissed = 0;
      await pump(
        tester,
        VoicePausedBanner(
          voiceCount: 214,
          manualCount: 3,
          onGetMinutes: () => getMinutes++,
          onDismiss: () => dismissed++,
        ),
      );

      expect(find.text('Voice paused'), findsOneWidget);
      expect(
        find.text(
          "You're out of voice minutes. Your count is safe, and tapping "
          'still works.',
        ),
        findsOneWidget,
      );
      expect(find.text('214 by voice'), findsOneWidget);
      expect(find.text('3 by tap'), findsOneWidget);

      await tester.tap(find.text('Get minutes'));
      await tester.tap(find.byTooltip('Dismiss'));
      expect(getMinutes, 1);
      expect(dismissed, 1);
    });
  });

  group('minutes in the voice banner', () {
    Future<void> pumpBanner(
      WidgetTester tester, {
      int? minutesLeft,
      bool low = false,
    }) => pump(
      tester,
      VoiceSessionBanner(
        status: EngineStatus.live,
        phrases: const ["I'm rich in wisdom"],
        voiceCount: 12,
        manualCount: 0,
        minutesLeft: minutesLeft,
        minutesLow: low,
        onStop: () {},
      ),
    );

    Color? pillColor(WidgetTester tester) {
      final pill = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('3 min left'),
              matching: find.byType(Container),
            )
            .first,
      );
      return (pill.decoration as BoxDecoration?)?.color;
    }

    testWidgets('shows how many are left', (tester) async {
      await pumpBanner(tester, minutesLeft: 23);
      expect(find.text('23 min left'), findsOneWidget);
    });

    testWidgets('shows nothing when there is no balance to show', (
      tester,
    ) async {
      await pumpBanner(tester);
      expect(find.textContaining('min left'), findsNothing);
    });

    testWidgets('turns amber when they are running low', (tester) async {
      await pumpBanner(tester, minutesLeft: 3);
      expect(pillColor(tester), isNot(VoiceWarningColors.background));

      await pumpBanner(tester, minutesLeft: 3, low: true);
      expect(pillColor(tester), VoiceWarningColors.background);
    });

    testWidgets('is read out in full', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpBanner(tester, minutesLeft: 1);
      expect(find.bySemanticsLabel('1 voice minute left'), findsOneWidget);
      handle.dispose();
    });
  });
}
