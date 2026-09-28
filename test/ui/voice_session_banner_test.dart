import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/ui/widgets/voice_session_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpBanner(
    WidgetTester tester, {
    required List<String> phrases,
    Map<String, int> phraseCounts = const {},
    String? lastMatchedPhrase,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VoiceSessionBanner(
            status: EngineStatus.live,
            phrases: phrases,
            voiceCount: phraseCounts.values.fold(0, (a, b) => a + b),
            manualCount: 0,
            phraseCounts: phraseCounts,
            lastMatchedPhrase: lastMatchedPhrase,
            onStop: () {},
          ),
        ),
      ),
    );
  }

  testWidgets('one phrase shows plainly, with nothing to expand', (
    tester,
  ) async {
    await pumpBanner(
      tester,
      phrases: ["I'm rich in wisdom"],
      phraseCounts: {"I'm rich in wisdom": 12},
    );

    expect(find.text('“I\'m rich in wisdom”'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
  });

  testWidgets('a set collapses to a label and expands to the split', (
    tester,
  ) async {
    await pumpBanner(
      tester,
      phrases: ["I'm rich in wisdom", 'I walk in favour'],
      phraseCounts: {"I'm rich in wisdom": 8, 'I walk in favour': 5},
      lastMatchedPhrase: 'I walk in favour',
    );

    expect(find.text('“I\'m rich in wisdom +1 more”'), findsOneWidget);
    // Collapsed by default: mid-session the total is what matters.
    expect(find.text('I walk in favour'), findsNothing);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
    await tester.pump();

    expect(find.text('I walk in favour'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    // The phrase just heard is marked, so the user can see what registered.
    expect(find.byIcon(Icons.graphic_eq_rounded), findsWidgets);
  });

  testWidgets('a phrase that has never matched still shows, at zero', (
    tester,
  ) async {
    // The whole point of the live split: a phrase stuck on zero is the
    // clearest sign it is not being recognised.
    await pumpBanner(
      tester,
      phrases: ["I'm rich in wisdom", 'My health is renewed'],
      phraseCounts: {"I'm rich in wisdom": 3},
    );

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
    await tester.pump();

    expect(find.text('My health is renewed'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
  });
}
