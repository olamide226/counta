import 'dart:convert';
import 'package:hive/hive.dart';

import '../../domain/models/phrase_history_entry.dart';
import '../../domain/validation/phrase_validator.dart';

abstract class PhraseHistoryRepository {
  List<PhraseHistoryEntry> getRecentPhrases({int limit = 5});
  Future<void> addOrUpdatePhrase(String rawPhrase);
  Future<void> clear();
}

class HivePhraseHistoryRepository implements PhraseHistoryRepository {
  static const String boxName = 'phrase_history';
  final Box _box;
  final PhraseValidator _validator = PhraseValidator();

  HivePhraseHistoryRepository(this._box);

  @override
  List<PhraseHistoryEntry> getRecentPhrases({int limit = 5}) {
    final entries = <PhraseHistoryEntry>[];
    for (final key in _box.keys) {
      final rawVal = _box.get(key);
      if (rawVal != null) {
        try {
          final Map<String, dynamic> jsonMap = rawVal is String
              ? jsonDecode(rawVal)
              : Map<String, dynamic>.from(rawVal);
          entries.add(PhraseHistoryEntry.fromJson(jsonMap));
        } catch (_) {}
      }
    }

    entries.sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
    return entries.take(limit).toList();
  }

  @override
  Future<void> addOrUpdatePhrase(String rawPhrase) async {
    final validation = _validator.validate(rawPhrase);
    if (!validation.isValid || validation.phraseSpec == null) return;

    final spec = validation.phraseSpec!;
    final normalisedKey = spec.normalisedTokens.join(' ');

    PhraseHistoryEntry entry;
    final existingRaw = _box.get(normalisedKey);

    if (existingRaw != null) {
      try {
        final Map<String, dynamic> jsonMap = existingRaw is String
            ? jsonDecode(existingRaw)
            : Map<String, dynamic>.from(existingRaw);
        final existing = PhraseHistoryEntry.fromJson(jsonMap);
        entry = existing.copyWith(
          raw: spec.raw,
          lastUsedAt: DateTime.now(),
          useCount: existing.useCount + 1,
        );
      } catch (_) {
        entry = PhraseHistoryEntry(
          normalised: normalisedKey,
          raw: spec.raw,
          lastUsedAt: DateTime.now(),
          useCount: 1,
        );
      }
    } else {
      entry = PhraseHistoryEntry(
        normalised: normalisedKey,
        raw: spec.raw,
        lastUsedAt: DateTime.now(),
        useCount: 1,
      );
    }

    await _box.put(normalisedKey, jsonEncode(entry.toJson()));
  }

  @override
  Future<void> clear() async {
    await _box.clear();
  }
}
