class PhraseHistoryEntry {
  final String normalised;
  final String raw;
  final DateTime lastUsedAt;
  final int useCount;

  const PhraseHistoryEntry({
    required this.normalised,
    required this.raw,
    required this.lastUsedAt,
    required this.useCount,
  });

  PhraseHistoryEntry copyWith({
    String? normalised,
    String? raw,
    DateTime? lastUsedAt,
    int? useCount,
  }) {
    return PhraseHistoryEntry(
      normalised: normalised ?? this.normalised,
      raw: raw ?? this.raw,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      useCount: useCount ?? this.useCount,
    );
  }

  Map<String, dynamic> toJson() => {
        'normalised': normalised,
        'raw': raw,
        'lastUsedAt': lastUsedAt.toIso8601String(),
        'useCount': useCount,
      };

  factory PhraseHistoryEntry.fromJson(Map<String, dynamic> json) =>
      PhraseHistoryEntry(
        normalised: json['normalised'] as String? ?? '',
        raw: json['raw'] as String? ?? '',
        lastUsedAt: json['lastUsedAt'] != null
            ? DateTime.tryParse(json['lastUsedAt'] as String) ?? DateTime.now()
            : DateTime.now(),
        useCount: (json['useCount'] as num?)?.toInt() ?? 1,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PhraseHistoryEntry &&
          runtimeType == other.runtimeType &&
          normalised == other.normalised;

  @override
  int get hashCode => normalised.hashCode;
}
