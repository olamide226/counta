import 'package:flutter_test/flutter_test.dart';
import 'package:counta/domain/validation/phrase_validator.dart';

void main() {
  group('PhraseValidator', () {
    late PhraseValidator validator;

    setUp(() {
      validator = PhraseValidator();
    });

    test('rejects empty or whitespace-only phrases', () {
      final res = validator.validate('   ');
      expect(res.isValid, false);
      expect(res.errorMessage, contains('Please enter a target phrase'));
    });

    test('rejects phrases with fewer than 2 tokens (Requirement 1.3)', () {
      final res = validator.validate('Hello');
      expect(res.isValid, false);
      expect(res.errorMessage, contains('at least 2 words'));
    });

    test('rejects phrases with more than 12 tokens (Requirement 1.4)', () {
      final longPhrase =
          'one two three four five six seven eight nine ten eleven twelve thirteen';
      final res = validator.validate(longPhrase);
      expect(res.isValid, false);
      expect(res.errorMessage, contains('12 or fewer words'));
    });

    test('accepts valid phrases between 2 and 12 tokens', () {
      final res = validator.validate("I'm rich in wisdom");
      expect(res.isValid, true);
      expect(res.phraseSpec, isNotNull);
      expect(res.phraseSpec!.raw, "I'm rich in wisdom");
      expect(res.phraseSpec!.normalisedTokens, ['i', 'am', 'rich', 'in', 'wisdom']);
      expect(res.phraseSpec!.keyterms, contains("I'm rich in wisdom"));
    });
  });
}
