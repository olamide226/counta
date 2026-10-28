import 'package:counta/domain/counting/block_service.dart';
import 'package:counta/domain/purchases/minute_store.dart';
import 'package:counta/state/providers/minute_store_provider.dart';
import 'package:counta/state/providers/supabase_providers.dart';
import 'package:counta/state/providers/voice_minutes_provider.dart';
import 'package:counta/ui/sheets/voice_minutes_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_minute_store.dart';
import '../helpers/voice_fakes.dart';

void main() {
  /// Opens the sheet from a button and hands back what it completed with.
  Future<_SheetResult> openSheet(
    WidgetTester tester,
    FakeBlockService service, {
    String? resumeLabel,
    String? successNote,
    String dismissLabel = 'Done',
    MinuteStore? store,
  }) async {
    final result = _SheetResult();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voiceMinutesProvider.overrideWith(
            // No real waiting between balance reads.
            (ref) => VoiceMinutesNotifier(service, pause: (_) async {}),
          ),
          minuteStoreProvider.overrideWithValue(store),
          supabaseSessionProvider.overrideWith((ref) async => null),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result.value = await showVoiceMinutesSheet(
                    context,
                    resumeLabel: resumeLabel,
                    successNote: successNote,
                    dismissLabel: dismissLabel,
                  );
                  result.closed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  Future<void> redeem(WidgetTester tester, String code) async {
    await tester.enterText(find.byType(TextField), code);
    await tester.pump();
    // With packs above it the field can sit below the fold of a test screen.
    await tester.ensureVisible(find.text('Redeem'));
    await tester.pump();
    await tester.tap(find.text('Redeem'));
    await tester.pumpAndSettle();
  }

  testWidgets('opens on the balance, freshly read', (tester) async {
    final service = FakeBlockService(balance: 23);
    await openSheet(tester, service);

    expect(find.text('23'), findsOneWidget);
    expect(find.text('minutes left'), findsOneWidget);
    expect(service.balanceReads, 1);
  });

  testWidgets('a balance that cannot be read says so, not zero', (
    tester,
  ) async {
    final service = FakeBlockService()
      ..balanceFailure = const BlockUnreachable('offline');
    await openSheet(tester, service);

    // Zero would be a claim. This is "don't know".
    expect(find.text('0'), findsNothing);
    expect(find.text("Couldn't check your minutes right now"), findsOneWidget);
  });

  testWidgets('there is nothing to redeem until something is typed', (
    tester,
  ) async {
    await openSheet(tester, FakeBlockService(balance: 0));

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Redeem'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('a good code adds minutes and says how many', (tester) async {
    final service = FakeBlockService(balance: 0)..vouchers['SPRING24'] = 50;
    final result = await openSheet(tester, service);

    await redeem(tester, 'spring24');

    expect(find.text('50 minutes added'), findsOneWidget);
    expect(find.text('50'), findsOneWidget);
    // Opened from Settings there is no session to go back to.
    expect(find.byIcon(Icons.mic), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();
    expect(result.closed, isTrue);
    expect(result.value, isFalse);
  });

  testWidgets('from a paused session, it offers to pick it back up', (
    tester,
  ) async {
    final service = FakeBlockService(balance: 0)..vouchers['SPRING24'] = 50;
    final result = await openSheet(
      tester,
      service,
      resumeLabel: 'Resume voice counting',
      successNote: 'Your count is where you left it.',
      dismissLabel: 'Keep counting by tapping',
    );
    expect(find.text('Keep counting by tapping'), findsOneWidget);

    await redeem(tester, 'SPRING24');
    expect(find.text('Your count is where you left it.'), findsOneWidget);

    await tester.tap(find.text('Resume voice counting'));
    await tester.pumpAndSettle();

    expect(result.value, isTrue);
  });

  testWidgets('a code that does not work says so, and the sheet stays', (
    tester,
  ) async {
    await openSheet(tester, FakeBlockService(balance: 0));

    await redeem(tester, 'SPRNG24');

    expect(
      find.text("That code didn't work. Check the spelling and try again."),
      findsOneWidget,
    );
    expect(find.text('0'), findsOneWidget);
    expect(find.textContaining('added'), findsNothing);
  });

  testWidgets('the error goes as soon as the code is corrected', (
    tester,
  ) async {
    await openSheet(tester, FakeBlockService(balance: 0));
    await redeem(tester, 'SPRNG24');

    await tester.enterText(find.byType(TextField), 'SPRING24');
    await tester.pump();

    // It described the code that was sent, not the one now in the field.
    expect(find.textContaining("didn't work"), findsNothing);
  });

  testWidgets('a code used twice is not counted twice', (tester) async {
    final service = FakeBlockService(balance: 0)..vouchers['SPRING24'] = 50;
    await openSheet(tester, service);
    await redeem(tester, 'SPRING24');
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await redeem(tester, 'SPRING24');

    expect(find.text("You've already used that code."), findsOneWidget);
    expect(find.text('50'), findsOneWidget);
  });

  testWidgets('no connection reads as a sentence and can be retried', (
    tester,
  ) async {
    final service = FakeBlockService(balance: 0)
      ..vouchers['SPRING24'] = 50
      ..redeemFailure = const BlockUnreachable('SocketException: failed');
    await openSheet(tester, service);

    await redeem(tester, 'SPRING24');
    expect(find.textContaining('SocketException'), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);

    service.redeemFailure = null;
    await tester.tap(find.text('Redeem'));
    await tester.pumpAndSettle();

    expect(find.text('50 minutes added'), findsOneWidget);
  });

  group('with minute packs on sale', () {
    testWidgets('lists them with store prices, the middle one chosen', (
      tester,
    ) async {
      final service = FakeBlockService(balance: 0);
      await openSheet(tester, service, store: FakeMinuteStore());

      expect(find.text('You have 0 minutes left'), findsOneWidget);
      expect(find.text('60 minutes'), findsOneWidget);
      expect(find.text('1 hour of voice counting'), findsOneWidget);
      expect(find.text('3 hours 20 minutes of voice counting'), findsOneWidget);
      expect(find.text('\$9.99'), findsOneWidget);
      expect(find.text('Buy 200 minutes'), findsOneWidget);
      // The code field waits behind a link, so the packs are the focus.
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Have a code?'), findsOneWidget);
    });

    testWidgets('best value goes to the cheapest per minute', (tester) async {
      await openSheet(
        tester,
        FakeBlockService(balance: 0),
        store: FakeMinuteStore(),
      );

      final best = find.ancestor(
        of: find.text('Best value'),
        matching: find.byType(Wrap),
      );
      expect(
        find.descendant(of: best, matching: find.text('500 minutes')),
        findsOneWidget,
      );
    });

    testWidgets('no pack is called best value when none is', (tester) async {
      await openSheet(
        tester,
        FakeBlockService(balance: 0),
        store: FakeMinuteStore(
          prices: const {
            'com.ruachtech.counta.credits.60': 6,
            'com.ruachtech.counta.credits.200': 20,
            'com.ruachtech.counta.credits.500': 50,
          },
        ),
      );

      expect(find.text('Best value'), findsNothing);
    });

    testWidgets('choosing a pack changes what the button buys', (tester) async {
      final store = FakeMinuteStore();
      await openSheet(tester, FakeBlockService(balance: 0), store: store);

      await tester.tap(find.text('500 minutes'));
      await tester.pump();
      await tester.tap(find.text('Buy 500 minutes'));
      await tester.pumpAndSettle();

      expect(store.bought, ['com.ruachtech.counta.credits.500']);
    });

    testWidgets('a purchase lands on the balance and says so', (tester) async {
      final service = FakeBlockService(balance: 3);
      final result = await openSheet(
        tester,
        service,
        store: FakeMinuteStore(credits: service),
        resumeLabel: 'Resume voice counting',
        successNote: 'Your count is where you left it.',
      );

      await tester.tap(find.text('Buy 200 minutes'));
      await tester.pumpAndSettle();

      expect(find.text('200 minutes added'), findsOneWidget);
      expect(find.text('203'), findsOneWidget);
      expect(find.text('Your count is where you left it.'), findsOneWidget);

      await tester.tap(find.text('Resume voice counting'));
      await tester.pumpAndSettle();
      expect(result.value, isTrue);
    });

    testWidgets('a purchase the server has not shown yet still succeeds', (
      tester,
    ) async {
      final service = FakeBlockService(balance: 3);
      // Paid, but nothing credited yet.
      await openSheet(tester, service, store: FakeMinuteStore());

      await tester.tap(find.text('Buy 200 minutes'));
      await tester.pumpAndSettle();

      expect(find.text('200 minutes added'), findsOneWidget);
      expect(find.text('They can take a moment to show up.'), findsOneWidget);
    });

    testWidgets('closing the store sheet is not an error', (tester) async {
      final store = FakeMinuteStore()
        ..nextOutcome = const PackPurchaseCancelled();
      await openSheet(tester, FakeBlockService(balance: 0), store: store);

      await tester.tap(find.text('Buy 200 minutes'));
      await tester.pumpAndSettle();

      expect(find.text('Buy 200 minutes'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);
    });

    testWidgets('a failed purchase says why, and can be tried again', (
      tester,
    ) async {
      final service = FakeBlockService(balance: 0);
      final store = FakeMinuteStore(credits: service)
        ..nextOutcome = const PackPurchaseFailed(
          "Couldn't reach the store. Check your connection and try again.",
        );
      await openSheet(tester, service, store: store);

      await tester.tap(find.text('Buy 200 minutes'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          "Couldn't reach the store. Check your connection and try again.",
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Buy 200 minutes'));
      await tester.pumpAndSettle();
      expect(find.text('200 minutes added'), findsOneWidget);
    });

    testWidgets('a purchase waiting for approval says so', (tester) async {
      final store = FakeMinuteStore()
        ..nextOutcome = const PackPurchasePending();
      await openSheet(tester, FakeBlockService(balance: 0), store: store);

      await tester.tap(find.text('Buy 200 minutes'));
      await tester.pumpAndSettle();

      expect(find.textContaining('waiting for approval'), findsOneWidget);
      expect(find.textContaining('added'), findsNothing);
    });

    testWidgets('a code still works alongside the packs', (tester) async {
      final service = FakeBlockService(balance: 0)..vouchers['SPRING24'] = 50;
      await openSheet(tester, service, store: FakeMinuteStore());

      await tester.tap(find.text('Have a code?'));
      await tester.pump();
      await redeem(tester, 'SPRING24');

      expect(find.text('50 minutes added'), findsOneWidget);
    });

    testWidgets('packs that will not load fall back to codes, and say so', (
      tester,
    ) async {
      await openSheet(
        tester,
        FakeBlockService(balance: 0),
        store: FakeMinuteStore(packsFailure: const MinuteStoreUnavailable()),
      );

      expect(find.byType(TextField), findsOneWidget);
      expect(
        find.text(
          "Minute packs couldn't load right now. You can still use a code.",
        ),
        findsOneWidget,
      );
      expect(find.textContaining('coming soon'), findsNothing);
    });
  });

  test('pack durations read as time', () {
    expect(packDuration(60), '1 hour of voice counting');
    expect(packDuration(200), '3 hours 20 minutes of voice counting');
    expect(packDuration(500), '8 hours 20 minutes of voice counting');
    expect(packDuration(45), '45 minutes of voice counting');
    expect(packDuration(120), '2 hours of voice counting');
  });
}

class _SheetResult {
  bool? value;
  bool closed = false;
}
