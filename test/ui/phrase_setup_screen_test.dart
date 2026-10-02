import 'dart:async';

import 'package:counta/domain/counting/block_service.dart';
import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/domain/models/phrase_history_entry.dart';
import 'package:counta/state/providers/voice_minutes_provider.dart';
import 'package:counta/ui/screens/phrase_setup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/voice_fakes.dart';

void main() {
  /// Pumps the screen and hands back the set the start button produced.
  Future<_StartedSet> pumpSetup(
    WidgetTester tester, {
    List<String>? initialPhrases,
    List<PhraseHistoryEntry> recentPhrases = const [],
    Object? throws,
    Future<void>? until,
    // Null is a build with no voice service: no minutes, nothing shown.
    FakeBlockService? service,
  }) async {
    final started = _StartedSet();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voiceMinutesProvider.overrideWith(
            (ref) => VoiceMinutesNotifier(service),
          ),
        ],
        child: MaterialApp(
          home: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => PhraseSetupScreen(
                initialPhrases: initialPhrases,
                recentPhrases: recentPhrases,
                onStartSession: (phrases) async {
                  if (until != null) await until;
                  if (throws != null) throw throws;
                  started.value = phrases;
                },
              ),
            ),
          ),
        ),
      ),
    );
    return started;
  }

  Finder rowAt(int index) => find.byType(TextField).at(index);

  testWidgets('opens as a single field, as it did before sets existed', (
    tester,
  ) async {
    await pumpSetup(tester);
    await tester.pumpAndSettle();

    // The common case must not pay for the feature: one field, and nothing
    // to remove.
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsNothing);
    expect(find.text('Target Phrase'), findsOneWidget);
    expect(find.text('Add another phrase'), findsOneWidget);
  });

  testWidgets('resume setup starts with the previous phrases', (tester) async {
    await pumpSetup(
      tester,
      initialPhrases: ['I am full of power', 'I walk in favour'],
    );
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNWidgets(2));
    expect(
      tester.widget<TextField>(rowAt(0)).controller?.text,
      'I am full of power',
    );
    expect(
      tester.widget<TextField>(rowAt(1)).controller?.text,
      'I walk in favour',
    );
    expect(find.text('Resume Voice Session'), findsOneWidget);
  });

  testWidgets('a second phrase is carried into the session', (tester) async {
    final started = await pumpSetup(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add another phrase'));
    await tester.pumpAndSettle();
    await tester.enterText(rowAt(1), 'I walk in favour');
    await tester.pumpAndSettle();

    // The label spells out that this is one total, not two counters.
    expect(find.text('Any of these counts towards the same total.'), findsOne);

    await tester.tap(find.text('Start Voice Session'));
    await tester.pumpAndSettle();

    expect(started.value?.rawPhrases, [
      "I'm rich in wisdom",
      'I walk in favour',
    ]);
  });

  testWidgets('a row added and left blank does not block starting', (
    tester,
  ) async {
    final started = await pumpSetup(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add another phrase'));
    await tester.pumpAndSettle();

    // Changing your mind about an extra phrase must not strand the session.
    expect(find.text('Please enter a target phrase to count.'), findsNothing);

    await tester.tap(find.text('Start Voice Session'));
    await tester.pumpAndSettle();

    expect(started.value?.rawPhrases, ["I'm rich in wisdom"]);
  });

  testWidgets('a phrase that only differs by contraction is refused', (
    tester,
  ) async {
    await pumpSetup(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add another phrase'));
    await tester.pumpAndSettle();
    await tester.enterText(rowAt(1), 'I am rich in wisdom');
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Same as phrase 1'),
      findsOneWidget,
      reason: 'the normaliser already treats these as one phrase',
    );
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNull,
    );
  });

  testWidgets('a phrase contained in another warns but still starts', (
    tester,
  ) async {
    final started = await pumpSetup(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add another phrase'));
    await tester.pumpAndSettle();
    await tester.enterText(rowAt(1), 'rich in wisdom');
    await tester.pumpAndSettle();

    expect(find.textContaining('is part of'), findsOneWidget);

    await tester.tap(find.text('Start Voice Session'));
    await tester.pumpAndSettle();

    expect(started.value?.length, 2);
  });

  testWidgets('a remembered set fills every row in one tap', (tester) async {
    await pumpSetup(
      tester,
      recentPhrases: [
        PhraseHistoryEntry(
          key: 'a | b | c',
          phrases: const [
            'I am full of power',
            'I walk in favour',
            'My health is renewed',
          ],
          lastUsedAt: DateTime(2026, 9, 1),
          useCount: 4,
        ),
      ],
    );
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('+2 more'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNWidgets(3));
    expect(
      tester.widget<TextField>(rowAt(2)).controller?.text,
      'My health is renewed',
    );
  });

  testWidgets('a long remembered set does not overflow its chip', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await pumpSetup(
      tester,
      recentPhrases: [
        PhraseHistoryEntry(
          key: 'long',
          phrases: const [
            'the wisdom of god is at work in me right now today',
            'I walk in favour and in the light of his countenance',
          ],
          lastUsedAt: DateTime(2026, 9, 1),
          useCount: 2,
        ),
      ],
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('a chip that would only duplicate a row is not offered', (
    tester,
  ) async {
    // The first row holds "I'm rich in wisdom". A recent phrase that
    // normalises to the same thing must not be offered, or tapping it would
    // produce an immediate duplicate error.
    await pumpSetup(
      tester,
      recentPhrases: [
        PhraseHistoryEntry(
          key: 'i am rich in wisdom',
          phrases: const ['I am rich in wisdom'],
          lastUsedAt: DateTime(2026, 9, 2),
          useCount: 3,
        ),
        PhraseHistoryEntry(
          key: 'i walk in favour',
          phrases: const ['I walk in favour'],
          lastUsedAt: DateTime(2026, 9, 1),
          useCount: 1,
        ),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('I am rich in wisdom'), findsNothing);
    expect(find.text('I walk in favour'), findsOneWidget);
  });

  testWidgets('a row can be removed again', (tester) async {
    await pumpSetup(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add another phrase'));
    await tester.pumpAndSettle();
    await tester.enterText(rowAt(1), 'I walk in favour');
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close_rounded).last);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsNothing);
  });

  testWidgets('a start that fails keeps the sheet open and says why', (
    tester,
  ) async {
    await pumpSetup(
      tester,
      throws: const VoiceUnavailable('Voice counting is not available.'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start Voice Session'));
    await tester.pumpAndSettle();

    // Popping on a failed start told the user the session had begun.
    expect(find.byType(PhraseSetupScreen), findsOneWidget);
    expect(find.text('Voice counting is not available.'), findsOneWidget);
  });

  testWidgets('a start in progress says so', (tester) async {
    // Starting takes a moment and the sheet waits for it. A button that only
    // went grey looked like the tap had done nothing.
    final started = Completer<void>();
    await pumpSetup(tester, until: started.future);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start Voice Session'));
    await tester.pump();

    expect(find.text('Starting…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // Still not tappable: one start at a time.
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNull,
    );

    started.complete();
    await tester.pumpAndSettle();
    expect(find.byType(PhraseSetupScreen), findsNothing);
  });

  testWidgets('running out of minutes is explained in plain words', (
    tester,
  ) async {
    // Regression: the screen interpolated the exception itself, and a tester
    // read "Could not start voice counting: BlockInsufficientCredit(balance:
    // 0, required: 5)".
    await pumpSetup(
      tester,
      throws: const BlockInsufficientCredit(balance: 0, required: 5),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start Voice Session'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'You have no voice minutes left. You can still count by tapping.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('BlockInsufficientCredit'), findsNothing);
    expect(find.textContaining('balance'), findsNothing);
    // The sheet stays open: the session did not start.
    expect(find.byType(PhraseSetupScreen), findsOneWidget);
  });

  testWidgets('an unexpected failure still reads as a sentence', (
    tester,
  ) async {
    await pumpSetup(tester, throws: StateError('socket closed'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start Voice Session'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining("Couldn't start voice counting. Please try again."),
      findsOneWidget,
    );
  });

  group('voice minutes', () {
    testWidgets('a build with no voice service shows nothing about minutes', (
      tester,
    ) async {
      await pumpSetup(tester);
      await tester.pumpAndSettle();

      expect(find.textContaining('voice minute'), findsNothing);
      expect(find.text('Start Voice Session'), findsOneWidget);
    });

    testWidgets('the balance is on the screen before starting', (tester) async {
      await pumpSetup(tester, service: FakeBlockService(balance: 23));
      await tester.pumpAndSettle();

      expect(find.text('23 voice minutes'), findsOneWidget);
      expect(find.text('Only used while voice counting is on'), findsOneWidget);
      expect(find.text('Get more'), findsOneWidget);
      expect(find.text('Start Voice Session'), findsOneWidget);
    });

    testWidgets('one minute is not "1 voice minutes"', (tester) async {
      await pumpSetup(
        tester,
        service: FakeBlockService(balance: 1)..required = 1,
      );
      await tester.pumpAndSettle();

      expect(find.text('1 voice minute'), findsOneWidget);
    });

    testWidgets('with none left, it says so instead of offering a start', (
      tester,
    ) async {
      await pumpSetup(tester, service: FakeBlockService(balance: 0));
      await tester.pumpAndSettle();

      // Known before the user tries, so they are not sent to be refused.
      expect(find.text('No voice minutes left'), findsOneWidget);
      expect(find.text('Get minutes'), findsOneWidget);
      expect(find.text('Count by tapping instead'), findsOneWidget);
      expect(find.text('Start Voice Session'), findsNothing);
    });

    testWidgets('too few to start says how many are needed', (tester) async {
      await pumpSetup(tester, service: FakeBlockService(balance: 3));
      await tester.pumpAndSettle();

      expect(find.text('Not enough voice minutes'), findsOneWidget);
      expect(
        find.textContaining('needs 5 minutes to start, and you have 3'),
        findsOneWidget,
      );
    });

    testWidgets('counting by tapping instead just goes back', (tester) async {
      final started = await pumpSetup(
        tester,
        service: FakeBlockService(balance: 0),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Count by tapping instead'));
      await tester.pumpAndSettle();

      expect(find.byType(PhraseSetupScreen), findsNothing);
      expect(started.value, isNull);
    });

    testWidgets('a code takes someone from no minutes to a running session', (
      tester,
    ) async {
      final service = FakeBlockService(balance: 0)..vouchers['SPRING24'] = 50;
      final started = await pumpSetup(tester, service: service);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Get minutes'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Enter your code'),
        'spring24',
      );
      await tester.pump();
      await tester.tap(find.text('Redeem'));
      await tester.pumpAndSettle();

      expect(find.text('50 minutes added'), findsOneWidget);

      // One tap from there to counting: the phrase is already typed.
      await tester.tap(find.text('Start voice counting'));
      await tester.pumpAndSettle();

      expect(started.value?.rawPhrases, ["I'm rich in wisdom"]);
      expect(find.byType(PhraseSetupScreen), findsNothing);
    });
  });

  testWidgets('a successful start closes the sheet', (tester) async {
    final started = await pumpSetup(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start Voice Session'));
    await tester.pumpAndSettle();

    expect(started.value?.rawPhrases, ["I'm rich in wisdom"]);
    expect(find.byType(PhraseSetupScreen), findsNothing);
  });
}

/// Mutable holder so the pump helper can report back what the screen started.
class _StartedSet {
  PhraseSet? value;
}
