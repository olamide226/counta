import 'package:counta/ui/widgets/session_summary_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('phraseBreakdown', () {
    test('lists every phrase in setup order, matched or not', () {
      final rows = phraseBreakdown(
        ["I'm rich in wisdom", 'I walk in favour', 'My health is renewed'],
        {"I'm rich in wisdom": 44, 'My health is renewed': 33},
      );

      expect(rows.map((r) => r.phrase), [
        "I'm rich in wisdom",
        'I walk in favour',
        'My health is renewed',
      ]);
      // A phrase at zero is the point: it means that one is not being heard.
      expect(rows.map((r) => r.count), [44, 0, 33]);
    });

    test('counts under a phrase no longer in the set still appear', () {
      // Resuming a session with a different setup leaves counts behind. They
      // are real counts, so dropping them would stop the rows adding up to
      // the voice total.
      final rows = phraseBreakdown(
        ['I walk in favour'],
        {'I walk in favour': 5, 'a phrase from earlier': 3},
      );

      expect(rows.map((r) => r.phrase), [
        'I walk in favour',
        'a phrase from earlier',
      ]);
      expect(rows.fold(0, (sum, r) => sum + r.count), 8);
    });
  });

  testWidgets('the card shows a row per phrase for a set', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionSummaryCard(
            title: "I'm rich in wisdom +1 more",
            total: 87,
            voiceCount: 85,
            manualCount: 2,
            isVoiceSession: true,
            phraseCounts: phraseBreakdown(
              ["I'm rich in wisdom", 'I walk in favour'],
              {"I'm rich in wisdom": 44, 'I walk in favour': 41},
            ),
          ),
        ),
      ),
    );

    expect(find.text('85 by voice · 2 by tap'), findsOneWidget);
    expect(find.text('“I\'m rich in wisdom”'), findsOneWidget);
    expect(find.text('44'), findsOneWidget);
    expect(find.text('41'), findsOneWidget);
  });

  testWidgets('a single phrase gets no breakdown rows', (tester) async {
    // With one phrase the rows would only restate the voice count.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionSummaryCard(
            title: "I'm rich in wisdom",
            total: 44,
            voiceCount: 44,
            manualCount: 0,
            isVoiceSession: true,
            phraseCounts: phraseBreakdown(
              ["I'm rich in wisdom"],
              {"I'm rich in wisdom": 44},
            ),
          ),
        ),
      ),
    );

    expect(find.text('“I\'m rich in wisdom”'), findsNothing);
    expect(find.byType(Divider), findsNothing);
  });
}
