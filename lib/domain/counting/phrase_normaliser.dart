/// Turns raw speech or user input into the token form the matcher compares.
///
/// Extracted from [PhraseMatcher] because validation needed the same rules:
/// building a throwaway matcher just to borrow one method meant any caller
/// that skipped it — as the debug screen did — silently tokenised differently
/// from production, expanding no contractions and mapping no homophones.
class PhraseNormaliser {
  const PhraseNormaliser({
    this.homophones = defaultHomophones,
    this.contractions = defaultContractions,
  });

  final Map<String, String> homophones;
  final Map<String, String> contractions;

  static const Map<String, String> defaultHomophones = {
    'won': 'one',
    'too': 'two',
    'to': 'two',
    'for': 'four',
  };

  static const Map<String, String> defaultContractions = {
    "i'm": 'i am',
    "im": 'i am',
    "don't": 'do not',
    "dont": 'do not',
    "can't": 'cannot',
    "cant": 'cannot',
    "it's": 'it is',
    "its": 'it is',
    "you're": 'you are',
    "youre": 'you are',
    "we're": 'we are',
    "were": 'we are',
    "they're": 'they are',
    "theyre": 'they are',
  };

  /// Patterns that never vary. Dart does not intern `RegExp`, so building
  /// these inline recompiled them on every call — and this runs once per word
  /// of every transcript segment.
  static final RegExp _punctuation = RegExp(r'[^\w\s]');
  static final RegExp _whitespace = RegExp(r'\s+');

  /// Lowercases, expands contractions, strips punctuation, tokenises, and
  /// maps homophones.
  List<String> call(String text) {
    if (text.trim().isEmpty) return const [];

    var str = text.toLowerCase();

    for (final entry in _contractionPatterns) {
      str = str.replaceAll(entry.pattern, entry.expansion);
    }

    str = str.replaceAll(_punctuation, '');

    return str
        .split(_whitespace)
        .where((t) => t.isNotEmpty)
        .map((t) => homophones[t] ?? t)
        .toList();
  }

  /// Contraction patterns compiled once per normaliser rather than per call.
  ///
  /// Cached by map identity so the common case — every caller sharing the
  /// default const map — compiles these exactly once for the whole process.
  List<({RegExp pattern, String expansion})> get _contractionPatterns =>
      _patternCache.putIfAbsent(
        contractions,
        () => [
          for (final entry in contractions.entries)
            (
              pattern: RegExp(r'\b' + RegExp.escape(entry.key) + r'\b'),
              expansion: entry.value,
            ),
        ],
      );

  static final Map<Map<String, String>,
      List<({RegExp pattern, String expansion})>> _patternCache = {};
}
