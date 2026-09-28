import 'package:counta/data/repositories/phrase_history_repository.dart';
import 'package:counta/domain/counting/counting_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import '../../helpers/temp_hive.dart';

void main() {
  PhraseSet setOf(List<String> raws) => PhraseSet([
    for (final raw in raws)
      PhraseSpec(raw: raw, normalisedTokens: raw.toLowerCase().split(' ')),
  ]);

  Future<T> withRepo<T>(
    Future<T> Function(HivePhraseHistoryRepository repo) body,
  ) {
    return withTempHive(() async {
      final box = await Hive.openBox(HivePhraseHistoryRepository.boxName);
      return body(HivePhraseHistoryRepository(box));
    });
  }

  test('a setup comes back as one entry, most recent first', () async {
    await withRepo((repo) async {
      await repo.record(setOf(['I walk in favour']));
      await repo.record(setOf(["I'm rich in wisdom", 'My health is renewed']));

      final recent = repo.getRecent();

      expect(recent, hasLength(2));
      expect(recent.first.phrases, [
        "I'm rich in wisdom",
        'My health is renewed',
      ]);
      expect(recent.first.isSet, isTrue);
      expect(recent.first.label, "I'm rich in wisdom +1 more");
      expect(recent.last.isSet, isFalse);
    });
  });

  test('the same setup is one entry with a rising use count', () async {
    await withRepo((repo) async {
      await repo.record(setOf(['I walk in favour']));
      await repo.record(setOf(['I walk in favour']));
      await repo.record(setOf(['I walk in favour']));

      final recent = repo.getRecent();

      expect(recent, hasLength(1));
      expect(recent.single.useCount, 3);
    });
  });

  test('a set is a different setup from its phrases alone', () async {
    await withRepo((repo) async {
      await repo.record(setOf(['I walk in favour']));
      await repo.record(setOf(['I walk in favour', "I'm rich in wisdom"]));

      expect(repo.getRecent(), hasLength(2));
    });
  });

  test('re-recording keeps the latest wording of the same setup', () async {
    await withRepo((repo) async {
      await repo.record(
        PhraseSet.single(
          const PhraseSpec(
            raw: 'Im rich',
            normalisedTokens: ['i', 'am', 'rich'],
          ),
        ),
      );
      await repo.record(
        PhraseSet.single(
          const PhraseSpec(
            raw: "I'm rich",
            normalisedTokens: ['i', 'am', 'rich'],
          ),
        ),
      );

      final recent = repo.getRecent();

      expect(recent, hasLength(1), reason: 'same normalised setup');
      expect(recent.single.phrases, ["I'm rich"]);
    });
  });

  test('history is trimmed rather than left to grow', () async {
    await withRepo((repo) async {
      for (var i = 0; i < HivePhraseHistoryRepository.maxEntries + 5; i++) {
        await repo.record(setOf(['phrase number $i']));
      }

      expect(
        repo.getRecent(limit: 100),
        hasLength(HivePhraseHistoryRepository.maxEntries),
      );
      // The ones kept are the most recent.
      expect(repo.getRecent().first.phrases.single, contains('number 24'));
    });
  });

  test('unparseable values cannot stop the box being trimmed', () async {
    // Regression: the gate counted raw box values while the deletion was
    // derived from entries that parse, so a box whose surplus was corrupt
    // never shrank and getRecent kept returning fewer than asked.
    await withTempHive(() async {
      final box = await Hive.openBox(HivePhraseHistoryRepository.boxName);
      final repo = HivePhraseHistoryRepository(box);
      for (var i = 0; i < HivePhraseHistoryRepository.maxEntries; i++) {
        await box.put('junk-$i', 'not json at all');
      }

      for (var i = 0; i < 5; i++) {
        await repo.record(setOf(['phrase number $i']));
      }

      expect(
        box.length,
        lessThanOrEqualTo(HivePhraseHistoryRepository.maxEntries),
      );
      expect(repo.getRecent(limit: 100), hasLength(5));
    });
  });

  test('a corrupt entry costs one chip, not the whole list', () async {
    await withTempHive(() async {
      final box = await Hive.openBox(HivePhraseHistoryRepository.boxName);
      final repo = HivePhraseHistoryRepository(box);
      await repo.record(setOf(['I walk in favour']));
      await box.put('rubbish', 'not json at all');

      expect(repo.getRecent(), hasLength(1));
    });
  });
}
