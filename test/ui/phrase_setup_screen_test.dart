import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/ui/screens/phrase_setup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('resume setup starts with the previous phrase', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PhraseSetupScreen(
          initialPhrase: 'I am full of power',
          onStartSession: (PhraseSpec _) async {},
        ),
      ),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, 'I am full of power');
    expect(find.text('Resume Voice Session'), findsOneWidget);
  });

  testWidgets('a start that fails keeps the sheet open and says why', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PhraseSetupScreen(
          onStartSession: (PhraseSpec _) async {
            throw const VoiceUnavailable('Voice counting is not available.');
          },
        ),
      ),
    );

    await tester.tap(find.text('Start Voice Session'));
    await tester.pumpAndSettle();

    // Popping on a failed start told the user the session had begun.
    expect(find.byType(PhraseSetupScreen), findsOneWidget);
    expect(find.text('Voice counting is not available.'), findsOneWidget);
  });

  testWidgets('a successful start closes the sheet', (tester) async {
    var started = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => PhraseSetupScreen(
              onStartSession: (PhraseSpec _) async => started++,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Start Voice Session'));
    await tester.pumpAndSettle();

    expect(started, 1);
    expect(find.byType(PhraseSetupScreen), findsNothing);
  });
}
