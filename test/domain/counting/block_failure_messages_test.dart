import 'package:counta/domain/counting/block_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Every refusal the voice service can give. A new subclass belongs in this
  // list: the wording rules below are only worth anything if they cover all
  // of them.
  final failures = <BlockFailure>[
    const BlockUnauthenticated(),
    const BlockInsufficientCredit(balance: 0, required: 5),
    const BlockInsufficientCredit(balance: 3, required: 5),
    const BlockInFlight(),
    const BlockRateLimited(),
    const BlockProviderUnavailable(),
    const BlockNotFound(),
    const BlockRequestRejected(status: 400, reason: 'bad_request'),
    const BlockUnreachable('SocketException: failed host lookup'),
  ];

  test('no message uses the words the code thinks in', () {
    // A tester was shown "Block insufficient credit. Balance zero, required
    // five". These are how the implementation names things, and none of them
    // means anything to someone counting a mantra.
    final internal = RegExp(
      r'block|credit|balance|required|exception|null|\(|\)|[A-Z][a-z]+[A-Z]',
      caseSensitive: true,
    );
    for (final failure in failures) {
      expect(
        internal.hasMatch(failure.message),
        isFalse,
        reason:
            '${failure.runtimeType} would show a user: "${failure.message}"',
      );
    }
  });

  test('every message says what to do, not only what went wrong', () {
    final nextStep = RegExp(
      r'try again|you can still count by tapping|start a new one|update the app',
      caseSensitive: false,
    );
    for (final failure in failures) {
      expect(
        nextStep.hasMatch(failure.message),
        isTrue,
        reason:
            '${failure.runtimeType}: "${failure.message}" leaves the user '
            'with nothing to do',
      );
    }
  });

  test('no message offers a way to buy minutes', () {
    // The purchase flow does not exist yet. Telling someone to "add minutes"
    // sends them looking for a button that is not there.
    final purchase = RegExp(
      r'\b(buy|purchase|add minutes|top up|upgrade)\b',
      caseSensitive: false,
    );
    for (final failure in failures) {
      expect(
        purchase.hasMatch(failure.message),
        isFalse,
        reason: '${failure.runtimeType}: "${failure.message}"',
      );
    }
  });

  group('running out of voice minutes', () {
    test('with none left, says so plainly', () {
      expect(
        const BlockInsufficientCredit(balance: 0, required: 5).message,
        'You have no voice minutes left. You can still count by tapping.',
      );
    });

    test('with some left, says how many and how many are needed', () {
      expect(
        const BlockInsufficientCredit(balance: 3, required: 5).message,
        'You have 3 voice minutes left, and a session needs 5. You can still '
        'count by tapping.',
      );
    });

    test('one minute is singular', () {
      expect(
        const BlockInsufficientCredit(balance: 1, required: 5).message,
        startsWith('You have 1 voice minute left,'),
      );
    });

    test('the log form keeps the numbers a developer needs', () {
      // toString stays technical on purpose; screens must show `message`.
      expect(
        const BlockInsufficientCredit(balance: 0, required: 5).toString(),
        'BlockInsufficientCredit(balance: 0, required: 5)',
      );
    });
  });
}
