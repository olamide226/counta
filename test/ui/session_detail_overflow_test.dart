import 'package:counta/domain/models/count_session.dart';
import 'package:counta/domain/models/enums.dart';
import 'package:counta/ui/screens/session_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a set of long phrases lays out without overflowing', (
    tester,
  ) async {
    // A phrase may be twelve words, and a session may hold five of them. On a
    // narrow phone that is the case most likely to run off the card.
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final now = DateTime(2026, 9, 1, 7);
    final session = CountSession(
      mantra: 'Morning',
      startedAt: now,
      endedAt: now.add(const Duration(minutes: 40)),
      finalCount: 120,
      soundMode: SoundMode.mute,
      themeModeChoice: ThemeModeChoice.system,
      themeId: AppThemeId.ocean,
      phrase: 'the wisdom of god is at work in me right now today',
      phrases: const [
        'the wisdom of god is at work in me right now today',
        'I walk in favour and in the light of his countenance',
        'my health is renewed day by day in every single way',
      ],
      phraseCounts: const {
        'the wisdom of god is at work in me right now today': 44,
        'I walk in favour and in the light of his countenance': 41,
        'my health is renewed day by day in every single way': 33,
      },
      voiceCount: 118,
      manualCount: 2,
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: SessionDetailScreen(session: session)),
      ),
    );
    await tester.pumpAndSettle();

    // The layout is the subject here: an unconstrained Column in a Row ran
    // the phrase list off the side of the card. Rows further down the page
    // are covered by the summary card's own test.
    expect(tester.takeException(), isNull);
    expect(find.text('Phrases counted'), findsOneWidget);
  });
}
