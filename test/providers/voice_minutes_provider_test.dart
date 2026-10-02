import 'package:counta/core/services/counting/observed_block_service.dart';
import 'package:counta/domain/counting/block_service.dart';
import 'package:counta/state/providers/voice_minutes_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/voice_fakes.dart';

void main() {
  var now = DateTime(2026, 10, 2, 12);
  setUp(() => now = DateTime(2026, 10, 2, 12));

  VoiceMinutesNotifier notifierFor(BlockService? service) {
    final notifier = VoiceMinutesNotifier(
      service,
      now: () => now,
      // Long enough that no test waits on it; the countdown is driven by
      // moving `now` and asking again.
      tick: const Duration(days: 1),
    );
    addTearDown(notifier.dispose);
    return notifier;
  }

  VoiceBlock block({required int balanceAfter, int seconds = 300}) =>
      VoiceBlock(
        id: 'b',
        deepgramToken: 't',
        blockSeconds: seconds,
        expiresAt: now.add(Duration(seconds: seconds)),
        balanceAfter: balanceAfter,
      );

  test('a build with no voice service has no minutes to show', () {
    final minutes = notifierFor(null).state;
    expect(minutes.available, isFalse);
    expect(minutes.left, isNull);
  });

  group('reading the balance', () {
    test('refresh takes what the server says', () async {
      final notifier = notifierFor(FakeBlockService(balance: 23));
      await notifier.refresh();

      expect(notifier.state.balance, 23);
      expect(notifier.state.left, 23);
      expect(notifier.state.canStart, isTrue);
    });

    test('a failed refresh leaves the old number alone', () async {
      final service = FakeBlockService(balance: 23);
      final notifier = notifierFor(service);
      await notifier.refresh();

      service.balanceFailure = const BlockUnreachable('offline');
      await notifier.refresh();

      // An old number beats an error for something nobody asked to do.
      expect(notifier.state.balance, 23);
    });

    test('a balance that has not loaded does not block starting', () {
      // The server decides. A slow first read must not stand between someone
      // and their practice.
      expect(notifierFor(FakeBlockService()).state.canStart, isTrue);
    });

    test('too few minutes to start is known before the user tries', () async {
      final notifier = notifierFor(FakeBlockService(balance: 3));
      await notifier.refresh();
      expect(notifier.state.canStart, isFalse);
    });
  });

  group('during a session', () {
    test('minutes left include the block already paid for', () {
      final notifier = notifierFor(FakeBlockService());
      notifier.onGranted(block(balanceAfter: 18), firstOfSession: true);

      // 18 unspent plus the 5 just bought.
      expect(notifier.state.left, 23);
      expect(notifier.state.sessionStart, 23);
    });

    test('the number counts down as the block runs', () {
      final notifier = notifierFor(FakeBlockService());
      notifier.onGranted(block(balanceAfter: 18), firstOfSession: true);

      now = now.add(const Duration(seconds: 61));
      notifier.onGranted(block(balanceAfter: 18), firstOfSession: false);
      // A renewal resets the paid window; ask about the first block instead.
      final running = notifier.state.copyWith(
        paidUntil: DateTime(2026, 10, 2, 12, 5),
        asOf: DateTime(2026, 10, 2, 12, 1, 1),
      );
      // 3 min 59 s of the block remain: four started minutes.
      expect(running.left, 18 + 4);
    });

    test('a renewal keeps the session-start figure', () {
      final notifier = notifierFor(FakeBlockService());
      notifier.onGranted(block(balanceAfter: 18), firstOfSession: true);
      notifier.onGranted(block(balanceAfter: 13), firstOfSession: false);

      expect(notifier.state.sessionStart, 23);
      expect(notifier.state.balance, 13);
    });

    test('low is a fifth of what the session started with', () {
      final notifier = notifierFor(FakeBlockService());
      notifier.onGranted(block(balanceAfter: 95), firstOfSession: true);
      expect(notifier.state.isLow, isFalse);

      final later = notifier.state.copyWith(balance: 15);
      expect(later.left, 20);
      expect(later.isLow, isTrue, reason: '20 of 100 is the fifth');
    });

    test('low is never less than three minutes', () {
      final notifier = notifierFor(FakeBlockService());
      notifier.onGranted(
        block(balanceAfter: 0, seconds: 180),
        firstOfSession: true,
      );
      // Started with 5: a fifth of that is 1, but 3 is the floor.
      expect(notifier.state.left, 3);
      expect(notifier.state.isLow, isTrue);
    });

    test('a refusal for lack of minutes brings the server\'s numbers', () {
      final notifier = notifierFor(FakeBlockService());
      notifier.onInsufficient(
        const BlockInsufficientCredit(balance: 2, required: 5),
      );
      expect(notifier.state.balance, 2);
      expect(notifier.state.canStart, isFalse);
    });
  });

  group('when a session stops', () {
    test('says what was used and what came back', () {
      final notifier = notifierFor(FakeBlockService());
      notifier.onGranted(block(balanceAfter: 18), firstOfSession: true);

      notifier.onReleased(
        const BlockRelease(
          refunded: true,
          balance: 22,
          usedCredits: 1,
          refundedCredits: 4,
        ),
      );

      final usage = notifier.state.lastUsage!;
      expect(usage.used, 1);
      expect(usage.returned, 4);
      expect(usage.left, 22);
      expect(notifier.state.paidUntil, isNull);
      expect(notifier.state.left, 22);
    });

    test('a session of several blocks adds them up', () {
      final notifier = notifierFor(FakeBlockService());
      notifier.onGranted(block(balanceAfter: 18), firstOfSession: true);
      notifier.onGranted(block(balanceAfter: 13), firstOfSession: false);

      notifier.onReleased(
        const BlockRelease(
          refunded: true,
          balance: 16,
          usedCredits: 2,
          refundedCredits: 3,
        ),
      );

      // Ten bought, three back.
      expect(notifier.state.lastUsage!.used, 7);
      expect(notifier.state.lastUsage!.returned, 3);
    });

    test('a block run to its end returns nothing', () {
      final notifier = notifierFor(FakeBlockService(balance: 18));
      notifier.onGranted(block(balanceAfter: 18), firstOfSession: true);

      notifier.onReleased(
        const BlockRelease(refunded: false, usedCredits: 5, refundedCredits: 0),
      );

      expect(notifier.state.lastUsage!.used, 5);
      expect(notifier.state.lastUsage!.returned, 0);
    });

    test('the next session starts from a clean count', () {
      final notifier = notifierFor(FakeBlockService());
      notifier.onGranted(block(balanceAfter: 18), firstOfSession: true);
      notifier.onReleased(
        const BlockRelease(
          refunded: true,
          balance: 22,
          usedCredits: 1,
          refundedCredits: 4,
        ),
      );

      notifier.onGranted(block(balanceAfter: 17), firstOfSession: true);
      expect(notifier.state.lastUsage, isNull);
      notifier.onReleased(
        const BlockRelease(
          refunded: true,
          balance: 20,
          usedCredits: 2,
          refundedCredits: 3,
        ),
      );
      expect(notifier.state.lastUsage!.used, 2);
    });
  });

  group('redeeming a code', () {
    test('a good code raises the balance', () async {
      final service = FakeBlockService(balance: 0)..vouchers['SPRING24'] = 50;
      final notifier = notifierFor(service);

      final outcome = await notifier.redeem('spring24');

      expect(outcome, isA<VoucherRedeemed>());
      expect(notifier.state.balance, 50);
    });

    test('a refused code changes nothing', () async {
      final service = FakeBlockService(balance: 7);
      final notifier = notifierFor(service);
      await notifier.refresh();

      final outcome = await notifier.redeem('NOPE');

      expect(outcome, isA<VoucherRefused>());
      expect(notifier.state.balance, 7);
    });

    test(
      'a transport failure is thrown, so the sheet can offer a retry',
      () async {
        final service = FakeBlockService()
          ..redeemFailure = const BlockUnreachable('offline');

        await expectLater(
          notifierFor(service).redeem('SPRING24'),
          throwsA(isA<BlockUnreachable>()),
        );
      },
    );
  });

  group('after a pack is bought', () {
    test('reads until the purchase shows', () async {
      final service = FakeBlockService(balance: 3);
      var reads = 0;
      final notifier = VoiceMinutesNotifier(
        service,
        pause: (_) async {
          // The store's server credits it between the second and third read.
          if (++reads == 2) service.balance += 200;
        },
      );
      addTearDown(notifier.dispose);

      final shown = await notifier.awaitPurchasedMinutes(before: 3);

      expect(shown, isTrue);
      expect(notifier.state.balance, 203);
      expect(service.balanceReads, 3);
    });

    test('gives up after a few reads without calling it lost', () async {
      final service = FakeBlockService(balance: 3);
      final notifier = VoiceMinutesNotifier(service, pause: (_) async {});
      addTearDown(notifier.dispose);

      final shown = await notifier.awaitPurchasedMinutes(before: 3);

      expect(shown, isFalse);
      expect(service.balanceReads, 5);
    });
  });

  group('ObservedBlockService', () {
    test('tells a renewal from a new session by its session id', () async {
      final firsts = <bool>[];
      final observed = ObservedBlockService(
        FakeBlockService(),
        onGranted: (_, {required firstOfSession}) => firsts.add(firstOfSession),
        onReleased: (_) {},
        onInsufficient: (_) {},
      );

      await observed.acquire('session-a');
      await observed.acquire('session-a');
      await observed.acquire('session-b');

      expect(firsts, [true, false, true]);
    });

    test('reports a refusal for lack of minutes and still throws it', () async {
      BlockInsufficientCredit? seen;
      final observed = ObservedBlockService(
        FakeBlockService(
          failures: const [BlockInsufficientCredit(balance: 1, required: 5)],
        ),
        onGranted: (_, {required firstOfSession}) {},
        onReleased: (_) {},
        onInsufficient: (refusal) => seen = refusal,
      );

      await expectLater(
        observed.acquire('s'),
        throwsA(isA<BlockInsufficientCredit>()),
      );
      expect(seen?.balance, 1);
    });

    test('does not dispose the shared service an engine hands back', () async {
      final inner = FakeBlockService();
      final observed = ObservedBlockService(
        inner,
        onGranted: (_, {required firstOfSession}) {},
        onReleased: (_) {},
        onInsufficient: (_) {},
      );

      await observed.dispose();

      // One service outlives every engine; an engine being replaced must not
      // close the connection the next one needs.
      expect(inner.disposed, isFalse);
    });
  });
}
