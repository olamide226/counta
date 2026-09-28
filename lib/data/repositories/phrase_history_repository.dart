import 'dart:convert';

import 'package:hive/hive.dart';

import '../hive/hive_init.dart';
import '../../domain/counting/counting_engine.dart';
import '../../domain/models/phrase_history_entry.dart';

abstract class PhraseHistoryRepository {
  /// Setups most recently used first.
  List<PhraseHistoryEntry> getRecent({int limit = 6});

  /// Remembers a setup a voice session actually started with.
  Future<void> record(PhraseSet phrases);

  Future<void> clear();
}

class HivePhraseHistoryRepository implements PhraseHistoryRepository {
  static const String boxName = 'phrase_history';

  /// Setups kept at all. History is a convenience, not a record — the saved
  /// sessions are the record — so it is trimmed rather than left to grow.
  static const int maxEntries = 20;

  final Box _box;

  HivePhraseHistoryRepository(this._box);

  /// The key is built from the normalised tokens the validator already
  /// produced, so it agrees with the duplicate check in setup by construction.
  static String keyFor(PhraseSet phrases) => [
    for (final phrase in phrases.phrases) phrase.normalisedTokens.join(' '),
  ].join(' | ');

  @override
  List<PhraseHistoryEntry> getRecent({int limit = 6}) {
    final entries = _readAll()
      ..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
    return entries.take(limit).toList();
  }

  List<PhraseHistoryEntry> _readAll() {
    final entries = <PhraseHistoryEntry>[];
    for (final value in _box.values) {
      if (value is! String) continue;
      try {
        final entry = PhraseHistoryEntry.fromJson(
          jsonDecode(value) as Map<String, dynamic>,
        );
        if (entry.phrases.isNotEmpty) entries.add(entry);
      } on FormatException {
        // A corrupt entry costs the user one chip, not the whole list.
      } on TypeError {
        // Same: an entry of the wrong shape is skipped, not fatal.
      }
    }
    return entries;
  }

  @override
  Future<void> record(PhraseSet phrases) async {
    final key = keyFor(phrases);
    final now = DateTime.now();

    final existing = _box.get(key);
    var useCount = 1;
    if (existing is String) {
      try {
        useCount =
            PhraseHistoryEntry.fromJson(
              jsonDecode(existing) as Map<String, dynamic>,
            ).useCount +
            1;
      } on FormatException {
        // Start the count again rather than refuse to remember the setup.
      } on TypeError {
        // As above.
      }
    }

    // The latest wording wins: retyping "Im rich" as "I'm rich" should show
    // the tidier one next time, not whichever came first.
    final entry = PhraseHistoryEntry(
      key: key,
      phrases: phrases.rawPhrases,
      lastUsedAt: now,
      useCount: useCount,
    );
    await _box.put(key, jsonEncode(entry.toJson()));
    await _trim();
  }

  Future<void> _trim() async {
    if (_box.length <= maxEntries) return;
    final stale =
        (_readAll()..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt)))
            .skip(maxEntries)
            .map((entry) => entry.key);
    await _box.deleteAll(stale);
  }

  @override
  Future<void> clear() async {
    await _box.clear();
  }
}

PhraseHistoryRepository createPhraseHistoryRepository() {
  return HivePhraseHistoryRepository(getPhraseHistoryBox());
}
