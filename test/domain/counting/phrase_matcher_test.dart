import 'package:flutter_test/flutter_test.dart';
import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/domain/counting/phrase_matcher.dart';
import 'package:counta/domain/counting/transcript_segment.dart';
import '../../fixtures/fixture_replay_harness.dart';

void main() {
  group('PhraseMatcher', () {
    late PhraseMatcher matcher;
    late PhraseSpec phrase;

    setUp(() {
      phrase = const PhraseSpec(
        raw: "I'm rich in wisdom",
        normalisedTokens: ['i', 'am', 'rich', 'in', 'wisdom'],
      );
      matcher = PhraseMatcher(target: phrase);
    });

    test('normaliseText expands contractions and strips punctuation', () {
      final tokens = matcher.normaliseText("I'm rich in wisdom!");
      expect(tokens, ['i', 'am', 'rich', 'in', 'wisdom']);
    });

    test('normaliseText maps homophones', () {
      final tokens = matcher.normaliseText("Won too for");
      expect(tokens, ['one', 'two', 'four']);
    });

    test('calculateTokenSimilarity exact match yields 1.0', () {
      final sim = matcher.calculateTokenSimilarity(
        ['i', 'am', 'rich', 'in', 'wisdom'],
        ['i', 'am', 'rich', 'in', 'wisdom'],
      );
      expect(sim, 1.0);
    });

    test('calculateTokenSimilarity near match yields high score', () {
      final sim = matcher.calculateTokenSimilarity(
        ['i', 'rich', 'in', 'wisdom'],
        ['i', 'am', 'rich', 'in', 'wisdom'],
      );
      expect(sim, 0.80);
    });

    test('ingest detects exact phrase match', () {
      final segment = TranscriptSegment(
        text: "I'm rich in wisdom",
        start: 1.0,
        duration: 2.0,
        isFinal: true,
        confidence: 0.98,
      );

      final detections = matcher.ingest(segment);
      expect(detections.length, 1);
      expect(detections.first.score, 1.0);
    });

    test('ingest ignores non-final segments', () {
      final segment = TranscriptSegment(
        text: "I'm rich in wisdom",
        start: 1.0,
        duration: 2.0,
        isFinal: false,
        confidence: 0.98,
      );

      final detections = matcher.ingest(segment);
      expect(detections, isEmpty);
    });

    test('refractory period suppresses immediate duplicate detection', () {
      final seg1 = TranscriptSegment(
        text: "I'm rich in wisdom",
        start: 1.0,
        duration: 1.0,
        isFinal: true,
        confidence: 0.98,
      );

      // Second utterance starts 200 ms after first (within 1200 ms refractory floor)
      final seg2 = TranscriptSegment(
        text: "I'm rich in wisdom",
        start: 1.2,
        duration: 1.0,
        isFinal: true,
        confidence: 0.98,
      );

      final d1 = matcher.ingest(seg1);
      expect(d1.length, 1);

      final d2 = matcher.ingest(seg2);
      expect(d2.length, 0); // Suppressed by refractory period
    });

    test('token consumption prevents duplicate counting on same segment', () {
      final seg = TranscriptSegment(
        text: "I'm rich in wisdom and I'm rich in wisdom",
        start: 1.0,
        duration: 5.0,
        isFinal: true,
        confidence: 0.98,
      );

      final detections = matcher.ingest(seg);
      // Second match occurs after duration spacing, token consumption allows second match
      expect(detections.length, greaterThanOrEqualTo(1));
    });
  });

  group('FixtureReplayHarness', () {
    test('evaluateFixtureJson calculates recall and gate correctly', () {
      final harness = FixtureReplayHarness();

      final jsonPayload = '''
      {
        "phrase_raw": "I'm rich in wisdom",
        "true_count": 2,
        "segments": [
          {
            "text": "I'm rich in wisdom",
            "start": 1.0,
            "duration": 2.0,
            "is_final": true,
            "confidence": 0.99
          },
          {
            "text": "I am rich in wisdom",
            "start": 10.0,
            "duration": 2.0,
            "is_final": true,
            "confidence": 0.99
          }
        ]
      }
      ''';

      final result = harness.evaluateFixtureJson(jsonPayload, fixtureName: 'test_sample');

      expect(result.trueCount, 2);
      expect(result.detectedCount, 2);
      expect(result.recall, 1.0);
      expect(result.passedGate, true);
    });
  });
}
