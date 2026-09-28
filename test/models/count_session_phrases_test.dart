import 'package:counta/domain/models/count_session.dart';
import 'package:counta/domain/models/enums.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import '../helpers/temp_hive.dart';

void main() {
  CountSession sessionWith({
    String? phrase,
    List<String>? phrases,
    Map<String, int>? phraseCounts,
  }) {
    final now = DateTime(2026, 9, 1, 7);
    return CountSession(
      mantra: 'Morning',
      startedAt: now,
      endedAt: now.add(const Duration(minutes: 20)),
      finalCount: 87,
      soundMode: SoundMode.mute,
      themeModeChoice: ThemeModeChoice.system,
      themeId: AppThemeId.ocean,
      phrase: phrase,
      phrases: phrases,
      phraseCounts: phraseCounts,
      voiceCount: 85,
      manualCount: 2,
    );
  }

  group('allPhrases', () {
    test('reads the list when the record has one', () {
      final session = sessionWith(
        phrase: "I'm rich in wisdom",
        phrases: ["I'm rich in wisdom", 'I walk in favour'],
      );

      expect(session.allPhrases, ["I'm rich in wisdom", 'I walk in favour']);
      expect(session.phraseLabel, "I'm rich in wisdom +1 more");
    });

    test('falls back to the single phrase of an older record', () {
      // Records written before multi-phrase sessions existed have `phrase`
      // and nothing else. They must still read as a voice session.
      final session = sessionWith(phrase: "I'm rich in wisdom");

      expect(session.allPhrases, ["I'm rich in wisdom"]);
      expect(session.phraseLabel, "I'm rich in wisdom");
      expect(session.isVoiceSession, isTrue);
    });

    test('a tap-only record has no phrases and no label', () {
      final session = sessionWith();

      expect(session.allPhrases, isEmpty);
      expect(session.phraseLabel, isNull);
    });
  });

  test('phrases and their counts survive a Hive round trip', () async {
    await withTempHive(() async {
      final box = await Hive.openBox<CountSession>('round_trip');
      final session = sessionWith(
        phrase: "I'm rich in wisdom",
        phrases: ["I'm rich in wisdom", 'I walk in favour'],
        phraseCounts: {"I'm rich in wisdom": 44, 'I walk in favour': 41},
      );

      await box.put(session.id, session);
      final restored = box.get(session.id)!;

      expect(restored.phrases, ["I'm rich in wisdom", 'I walk in favour']);
      expect(restored.phraseCounts, {
        "I'm rich in wisdom": 44,
        'I walk in favour': 41,
      });
      // The map has to come back typed, not as Map<dynamic, dynamic>.
      expect(restored.phraseCounts, isA<Map<String, int>>());
      expect(restored.phrases, isA<List<String>>());
    });
  });

  test('a record saved without the new fields still loads', () async {
    await withTempHive(() async {
      final box = await Hive.openBox<CountSession>('legacy');
      final legacy = sessionWith(phrase: "I'm rich in wisdom");

      await box.put(legacy.id, legacy);
      final restored = box.get(legacy.id)!;

      expect(restored.phrases, isNull);
      expect(restored.phraseCounts, isNull);
      expect(restored.allPhrases, ["I'm rich in wisdom"]);
    });
  });
}
