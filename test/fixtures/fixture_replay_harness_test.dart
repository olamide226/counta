import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'fixture_replay_harness.dart';

void main() {
  /// A fixture whose transcript is the given utterances, two seconds each.
  String fixture(Map<String, Object?> header, List<String> utterances) {
    return jsonEncode({
      ...header,
      'segments': [
        for (int i = 0; i < utterances.length; i++)
          {
            'text': utterances[i],
            'start': i * 3.0,
            'duration': 2.0,
            'is_final': true,
            'confidence': 0.95,
          },
      ],
    });
  }

  final harness = FixtureReplayHarness();

  group('a fixture recorded with several phrases', () {
    const wisdom = "I'm rich in wisdom";
    const favour = 'I walk in favour';

    final json = fixture(
      {
        'phrase_raw': wisdom,
        'phrases_raw': [wisdom, favour],
        'true_count': 5,
        'true_counts': [3, 2],
      },
      [
        'i am rich in wisdom',
        'i walk in favour',
        'i am rich in wisdom',
        'i walk in favour',
        'i am rich in wisdom',
      ],
    );

    test('replays against every phrase and splits the result', () {
      final result = harness.evaluateFixtureJson(json);

      expect(result.isMultiPhrase, isTrue);
      expect(result.detectedCount, 5);
      expect(result.phrases.map((p) => p.phrase), [wisdom, favour]);
      expect(result.phrases.map((p) => p.detectedCount), [3, 2]);
      expect(result.phrases.map((p) => p.trueCount), [3, 2]);
    });

    test('tracks each phrase by words no other phrase uses', () {
      final result = harness.evaluateFixtureJson(json);

      // "i" and "in" are in both phrases; counting either would credit each
      // phrase with the other's repetitions.
      expect(result.phrases[0].trackedWords, ['am', 'rich', 'wisdom']);
      expect(result.phrases[1].trackedWords, ['walk', 'favour']);
      expect(result.phrases.map((p) => p.transcribedRepetitions), [3, 2]);
      expect(result.transcribedRepetitions, 5);
      expect(result.matcherRecall, 1.0);
    });

    test('per-phrase counts that do not line up are ignored, not guessed', () {
      final misaligned = fixture(
        {
          'phrases_raw': [wisdom, favour],
          'true_count': 5,
          'true_counts': [5],
        },
        ['i am rich in wisdom'],
      );

      final result = harness.evaluateFixtureJson(misaligned);

      expect(result.trueCount, 5);
      expect(result.phrases.map((p) => p.trueCount), [null, null]);
    });
  });

  test('a fixture from before phrase sets still replays', () {
    final json = fixture(
      {'phrase_raw': "I'm rich in wisdom", 'true_count': 2},
      ['i am rich in wisdom', 'i am rich in wisdom'],
    );

    final result = harness.evaluateFixtureJson(json);

    expect(result.isMultiPhrase, isFalse);
    expect(result.detectedCount, 2);
    expect(result.phrases.single.detectedCount, 2);
    expect(result.transcribedRepetitions, 2);
  });

  test('a misspelled word in the phrase does not wreck the estimate', () {
    // normal_30, in miniature. The phrase was typed "annointing"; the
    // transcript mostly holds the correct spelling. Counting only the longest
    // word saw 1 repetition where there were 4, and reported 400% recall.
    final json = fixture(
      {'phrase_raw': 'I receive the annointing of joy', 'true_count': 4},
      [
        'i receive the anointing of joy',
        'i received the anointing of joy',
        'i receive the annointing of joy',
        'i receive the anointing of joy',
      ],
    );

    final result = harness.evaluateFixtureJson(json);

    expect(result.transcribedRepetitions, 4);
    expect(result.detectedCount, 4);
    expect(result.matcherRecall, 1.0);
  });

  test('a phrase contained in another is flagged as sharing its words', () {
    final json = fixture(
      {
        'phrases_raw': ["I'm rich in wisdom", 'rich in wisdom'],
        'true_count': 2,
      },
      ['i am rich in wisdom', 'i am rich in wisdom'],
    );

    final result = harness.evaluateFixtureJson(json);

    expect(result.phrases[0].anchorShared, isFalse);
    expect(result.phrases[1].anchorShared, isTrue);
    // Estimated from the containing phrase alone: adding the contained one
    // would count the same two repetitions twice.
    expect(result.transcribedRepetitions, 2);
  });

  test('detections by phrases the speaker never said are kept apart', () {
    final json = fixture(
      {'phrase_raw': "I'm rich in wisdom", 'true_count': 1},
      ['i am rich in wisdom', 'i walk in favour'],
    );

    final result = harness.evaluateFixtureJson(
      json,
      extraPhrases: ['I walk in favour'],
    );

    // This distractor really is in the audio, so it is detected — and it
    // must be reported as a distractor rather than folded into the phrase.
    expect(result.distractorDetections, 1);
    expect(result.phrases.single.detectedCount, 1);
  });

  test('a small fixture is reported but never gated', () {
    final json = fixture(
      {'phrase_raw': "I'm rich in wisdom", 'true_count': 2},
      ['i am rich in wisdom', 'i am rich in wisdom'],
    );

    expect(harness.evaluateFixtureJson(json).isGateable, isFalse);
  });
}
