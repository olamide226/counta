import 'package:counta/domain/validation/phrase_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final validator = PhraseValidator();

  group('validateSet', () {
    test('accepts several distinct phrases in the order given', () {
      final result = validator.validateSet([
        "I'm rich in wisdom",
        'I walk in favour',
      ]);

      expect(result.isValid, isTrue);
      expect(result.phraseSet?.rawPhrases, [
        "I'm rich in wisdom",
        'I walk in favour',
      ]);
      expect(result.warnings, isEmpty);
    });

    test('a blank row is not a phrase, and not an error either', () {
      // The screen adds a row before the user types in it, and they may never
      // type in it. That must not stop the session.
      final result = validator.validateSet(["I'm rich in wisdom", '', '  ']);

      expect(result.isValid, isTrue);
      expect(result.phraseSet?.rawPhrases, ["I'm rich in wisdom"]);
      expect(result.errors, [null, null, null]);
    });

    test('a setup with nothing in it is rejected on the first row', () {
      final result = validator.validateSet(['', '']);

      expect(result.isValid, isFalse);
      expect(result.errors.first, contains('enter a target phrase'));
      expect(result.errors[1], isNull);
    });

    test('an empty list is rejected rather than crashing', () {
      final result = validator.validateSet([]);

      expect(result.isValid, isFalse);
      expect(result.errors, hasLength(1));
    });

    test('phrases that normalise the same way are refused', () {
      // The normaliser already expands "I'm" to "I am", so these are one
      // target. Allowing both would leave the second on zero all session.
      final result = validator.validateSet([
        "I'm rich in wisdom",
        'I am rich in wisdom!',
      ]);

      expect(result.isValid, isFalse);
      expect(result.errors[0], isNull);
      expect(result.errors[1], contains('Same as phrase 1'));
    });

    test('the duplicate error names the row the user can see', () {
      final result = validator.validateSet([
        '',
        'I walk in favour',
        'I walk in favour',
      ]);

      expect(result.errors[2], contains('Same as phrase 2'));
    });

    test('a phrase contained in another warns without blocking', () {
      final result = validator.validateSet([
        "I'm rich in wisdom",
        'rich in wisdom',
      ]);

      expect(result.isValid, isTrue);
      expect(result.warnings, hasLength(1));
      expect(result.warnings.single, contains('is part of'));
    });

    test('a per-row problem is reported against that row alone', () {
      final result = validator.validateSet(['I walk in favour', 'no']);

      expect(result.isValid, isFalse);
      expect(result.errors[0], isNull);
      expect(result.errors[1], contains('at least 2 words'));
    });

    test('more phrases than a session can count is refused', () {
      final phrases = [
        'I walk in favour',
        "I'm rich in wisdom",
        'My health is renewed',
        'I am full of power',
        'the peace of god is mine',
        'one phrase too many',
      ];
      expect(phrases, hasLength(PhraseValidator.maxPhrases + 1));

      final result = validator.validateSet(phrases);

      expect(result.isValid, isFalse);
      expect(result.errors.last, contains('up to 5 phrases'));
    });

    test('the cap counts phrases, not rows', () {
      // Blank rows between phrases must not eat into the allowance.
      final result = validator.validateSet([
        'I walk in favour',
        '',
        "I'm rich in wisdom",
        '',
      ]);

      expect(result.isValid, isTrue);
      expect(result.phraseSet?.length, 2);
    });
  });
}
