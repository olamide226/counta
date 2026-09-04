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
          onStartSession: (PhraseSpec _) {},
        ),
      ),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, 'I am full of power');
    expect(find.text('Resume Voice Session'), findsOneWidget);
  });
}
