import 'package:counta/domain/counting/block_service.dart';
import 'package:counta/state/providers/voice_minutes_provider.dart';
import 'package:counta/ui/sheets/voice_minutes_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/voice_fakes.dart';

void main() {
  /// Opens the sheet from a button and hands back what it completed with.
  Future<_SheetResult> openSheet(
    WidgetTester tester,
    FakeBlockService service, {
    String? resumeLabel,
    String? successNote,
    String dismissLabel = 'Done',
  }) async {
    final result = _SheetResult();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voiceMinutesProvider.overrideWith(
            (ref) => VoiceMinutesNotifier(service),
          ),
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
}

class _SheetResult {
  bool? value;
  bool closed = false;
}
