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
    return PhraseValidationResult._(isValid: true, phraseSpec: phraseSpec);
  }

  factory PhraseValidationResult.error(String message) {
    return PhraseValidationResult._(isValid: false, errorMessage: message);
  }
}

/// Outcome of validating a whole set of phrase inputs together.
///
/// Rows are validated individually *and* against each other: two phrases that
/// normalise the same way are not two phrases, and one contained in another
/// changes which of them will win a shared utterance. Neither problem is
/// visible when each row is checked alone.
class PhraseSetValidationResult {
  const PhraseSetValidationResult({
    required this.errors,
    required this.warnings,
    this.phraseSet,
  });

  /// One entry per input row, in the order given. Null where the row is fine.
  final List<String?> errors;

  /// Set-level notices that do not block starting a session.
  final List<String> warnings;

  /// Non-null only when every row is valid.
  final PhraseSet? phraseSet;

  bool get isValid => phraseSet != null;
}

class PhraseValidator {
  final MatcherConfig matcherConfig;

  PhraseValidator({this.matcherConfig = const MatcherConfig()});

  /// Most phrases anyone can hold in their head mid-session, and the point
  /// past which extra targets cost accuracy: every phrase is another chance
  /// for an unrelated stretch of speech to clear the threshold.
  static const int maxPhrases = 5;

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

  /// Validates every row of a multi-phrase setup, plus the relationships
  /// between them.
  ///
  /// A blank row is not an error, it is simply not a phrase: adding a row and
  /// then leaving it empty must not stop a session starting. Only a setup with
  /// no phrase at all is rejected, and that error lands on the first row.
  /// Errors are reported against the row they belong to, so "same as phrase 2"
  /// names the row the user can actually see as the second one.
  PhraseSetValidationResult validateSet(List<String> rawPhrases) {
    final errors = List<String?>.filled(
      rawPhrases.isEmpty ? 1 : rawPhrases.length,
      null,
    );
    final warnings = <String>[];
    final specs = List<PhraseSpec?>.filled(rawPhrases.length, null);

    var filled = 0;
    for (int i = 0; i < rawPhrases.length; i++) {
      if (rawPhrases[i].trim().isEmpty) continue;
      if (++filled > maxPhrases) {
        errors[i] = 'You can count up to $maxPhrases phrases in one session.';
        continue;
      }
      final result = validate(rawPhrases[i]);
      errors[i] = result.errorMessage;
      specs[i] = result.phraseSpec;
    }

    if (filled == 0) {
      errors[0] = validate('').errorMessage;
      return PhraseSetValidationResult(errors: errors, warnings: warnings);
    }

    // Cross-row checks only make sense between rows that are valid on their
    // own; a row already showing an error should not gain a second one.
    final seen = <String, int>{};
    for (int i = 0; i < specs.length; i++) {
      final spec = specs[i];
      if (spec == null) continue;
      final key = spec.normalisedTokens.join(' ');

      final firstIndex = seen[key];
      if (firstIndex != null) {
        // Not a warning: identical targets cannot both win an utterance, so
        // the later one would sit at zero all session and look broken.
        errors[i] =
            'Same as phrase ${firstIndex + 1} once punctuation and '
            'contractions are ignored.';
        specs[i] = null;
        continue;
      }
      seen[key] = i;
    }

    for (final a in specs) {
      for (final b in specs) {
        if (a == null || b == null || identical(a, b)) continue;
        if (_containsTokens(b.normalisedTokens, a.normalisedTokens)) {
          warnings.add(
            '“${a.raw}” is part of “${b.raw}”. Saying the longer one counts '
            'once, towards the longer one.',
          );
        }
      }
    }

    final valid = [
      for (final spec in specs)
        if (spec != null) spec,
    ];
    final complete = errors.every((e) => e == null);

    return PhraseSetValidationResult(
      errors: errors,
      warnings: warnings,
      phraseSet: complete ? PhraseSet(valid) : null,
    );
  }

  /// Whether [needle] appears as a contiguous run inside [haystack].
  static bool _containsTokens(List<String> haystack, List<String> needle) {
    if (needle.isEmpty || needle.length >= haystack.length) return false;
    for (int i = 0; i + needle.length <= haystack.length; i++) {
      var matched = true;
      for (int j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return true;
    }
    return false;
  }
}
