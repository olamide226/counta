import '../counting/counting_engine.dart';
import '../counting/phrase_matcher.dart';
import '../counting/phrase_normaliser.dart';

class PhraseValidationResult {
  final bool isValid;
  final String? errorMessage;
  final PhraseSpec? phraseSpec;

  const PhraseValidationResult._({
    required this.isValid,
    this.errorMessage,
    this.phraseSpec,
  });

  factory PhraseValidationResult.success(PhraseSpec phraseSpec) {
    return PhraseValidationResult._(
      isValid: true,
      phraseSpec: phraseSpec,
    );
  }

  factory PhraseValidationResult.error(String message) {
    return PhraseValidationResult._(
      isValid: false,
      errorMessage: message,
    );
  }
}

class PhraseValidator {
  final MatcherConfig matcherConfig;

  PhraseValidator({
    this.matcherConfig = const MatcherConfig(),
  });

  /// Normalises and validates a raw phrase input string.
  PhraseValidationResult validate(String rawPhrase) {
    final trimmed = rawPhrase.trim();
    if (trimmed.isEmpty) {
      return PhraseValidationResult.error(
        'Please enter a target phrase to count.',
      );
    }

    final tokens = PhraseNormaliser(
      homophones: matcherConfig.homophones,
      contractions: matcherConfig.contractions,
    )(trimmed);

    if (tokens.length < 2) {
      return PhraseValidationResult.error(
        'Phrases must contain at least 2 words for reliable counting.',
      );
    }

    if (tokens.length > 12) {
      return PhraseValidationResult.error(
        'Phrases must contain 12 or fewer words to fit the matching window.',
      );
    }

    // Keyterms biased towards phrase and key n-grams
    final List<String> keyterms = [trimmed];

    final spec = PhraseSpec(
      raw: trimmed,
      normalisedTokens: tokens,
      keyterms: keyterms,
      languageCode: 'en',
    );

    return PhraseValidationResult.success(spec);
  }
}
