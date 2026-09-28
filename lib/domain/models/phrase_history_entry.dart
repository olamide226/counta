import '../counting/counting_engine.dart';

/// A phrase setup the user has started a voice session with before: one
/// phrase, or a set of them.
///
/// A set is remembered as a whole rather than as its separate phrases, because
/// someone who chants the same four affirmations every morning wants those
/// four back in one tap, not four chips to reassemble.
class PhraseHistoryEntry {
  /// Identity of the setup: each phrase's normalised form, in order. Two
  /// setups that differ only in punctuation or contractions are the same one.
  final String key;

  /// The phrases as the user typed them, in setup order.
  final List<String> phrases;

  final DateTime lastUsedAt;
  final int useCount;

  const PhraseHistoryEntry({
    required this.key,
    required this.phrases,
    required this.lastUsedAt,
    required this.useCount,
  });

  bool get isSet => phrases.length > 1;

  String get label => phraseSetLabel(phrases);

  PhraseHistoryEntry copyWith({
    List<String>? phrases,
    DateTime? lastUsedAt,
    int? useCount,
  }) {
    return PhraseHistoryEntry(
      key: key,
      phrases: phrases ?? this.phrases,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      useCount: useCount ?? this.useCount,
    );
  }

  Map<String, dynamic> toJson() => {
    'key': key,
    'phrases': phrases,
    'lastUsedAt': lastUsedAt.toIso8601String(),
    'useCount': useCount,
  };

  factory PhraseHistoryEntry.fromJson(Map<String, dynamic> json) =>
      PhraseHistoryEntry(
        key: json['key'] as String? ?? '',
        phrases: [
          for (final phrase in json['phrases'] as List? ?? const [])
            if (phrase is String) phrase,
        ],
        lastUsedAt:
            DateTime.tryParse(json['lastUsedAt'] as String? ?? '') ??
            DateTime.now(),
        useCount: (json['useCount'] as num?)?.toInt() ?? 1,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PhraseHistoryEntry &&
          runtimeType == other.runtimeType &&
          key == other.key;

  @override
  int get hashCode => key.hashCode;
}
