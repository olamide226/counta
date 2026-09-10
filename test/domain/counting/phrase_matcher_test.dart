import 'package:flutter_test/flutter_test.dart';
import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/domain/counting/phrase_matcher.dart';
import 'package:counta/domain/counting/transcript_segment.dart';
import '../../fixtures/fixture_replay_harness.dart';
import '../../helpers/transcript_fixtures.dart';

void main() {
  group('PhraseMatcher', () {
    late PhraseMatcher matcher;
    setUp(() => matcher = PhraseMatcher(target: testPhrase));

    test('normaliseText expands contractions and strips punctuation', () {
      final tokens = matcher.normaliseText("I'm rich in wisdom!");
      expect(tokens, ['i', 'am', 'rich', 'in', 'wisdom']);
    });

    test('normaliseText treats curly and straight apostrophes equally', () {
      expect(
        matcher.normaliseText('I’m full of power'),
        matcher.normaliseText("I'm full of power"),
      );
      expect(matcher.normaliseText('I’m full of power'), [
        'i',
        'am',
        'full',
        'of',
        'power',
      ]);
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

      // Second utterance starts before the first ends, so it is a duplicate.
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

    test('accepts a rapid repetition when the audio does not overlap', () {
      final first = TranscriptSegment(
        text: "I'm rich in wisdom",
        start: 1.0,
        duration: 1.0,
        isFinal: true,
        confidence: 0.98,
      );
      final second = TranscriptSegment(
        text: "I'm rich in wisdom",
        start: 2.05,
        duration: 1.0,
        isFinal: true,
        confidence: 0.98,
      );

      expect(matcher.ingest(first), hasLength(1));
      final detections = matcher.ingest(second);
      expect(detections, hasLength(1));
      expect(detections.single.audioOffset, const Duration(milliseconds: 2050));
    });

    test('a lightly misheard word costs less than an unrelated one', () {
      final target = [
        'the',
        'wisdom',
        'of',
        'god',
        'is',
        'at',
        'work',
        'in',
        'me',
      ];
      final inflected = matcher.calculateTokenSimilarity([
        'the',
        'wisdom',
        'of',
        'god',
        'is',
        'at',
        'working',
        'in',
        'me',
      ], target);
      final unrelated = matcher.calculateTokenSimilarity([
        'the',
        'wisdom',
        'of',
        'god',
        'is',
        'at',
        'peace',
        'in',
        'me',
      ], target);
      expect(inflected, greaterThan(unrelated));
      expect(unrelated, closeTo(1 - 1 / 9, 0.001));
    });

    test('short tokens never fuzzy-match each other', () {
      final sim = matcher.calculateTokenSimilarity(
        ['i', 'am', 'rich', 'is', 'wisdom'],
        ['i', 'am', 'rich', 'in', 'wisdom'],
      );
      expect(sim, closeTo(0.80, 0.001));
    });

    group('anchored relaxation', () {
      final long = PhraseSpec(
        raw: 'The wisdom of God is at work in me',
        normalisedTokens: const [
          'the',
          'wisdom',
          'of',
          'god',
          'is',
          'at',
          'work',
          'in',
          'me',
        ],
      );

      // The shared builder, at the length and confidence a long phrase gets.
      TranscriptSegment saidOnce(String text) =>
          finalSegment(text, duration: 3.0, confidence: 0.9);

      test('accepts a repetition whose middle is garbled', () {
        // Recorded in normal_426: scores 0.70, below the plain threshold.
        final m = PhraseMatcher(target: long);
        final detections = m.ingest(
          saidOnce('the wisdom of god is how to walk in me'),
        );
        expect(detections, hasLength(1));
      });

      test('does not relax when the head is missing', () {
        final m = PhraseMatcher(target: long);
        expect(m.ingest(saidOnce('gods wisdom is at work in me')), isEmpty);
      });

      test('does not relax when the tail is missing', () {
        final m = PhraseMatcher(target: long);
        expect(
          m.ingest(saidOnce('the wisdom of god is how to walk in')),
          isEmpty,
        );
      });

      test('can be disabled by matching the plain threshold', () {
        final m = PhraseMatcher(
          target: long,
          config: const MatcherConfig(anchoredThreshold: 0.80),
        );
        expect(
          m.ingest(saidOnce('the wisdom of god is how to walk in me')),
          isEmpty,
        );
      });

      test('never applies to phrases too short to have a middle', () {
        const short = PhraseSpec(
          raw: 'I breakthrough',
          normalisedTokens: ['i', 'breakthrough'],
        );
        final m = PhraseMatcher(target: short);
        expect(m.ingest(saidOnce('i did breakthrough')), isEmpty);
      });
    });

    test('prefers the exact phrase over a longer phrase with noise', () {
      final segment = TranscriptSegment(
        text: "I'm rich in wisdom shout",
        start: 1.0,
        duration: 2.0,
        isFinal: true,
        confidence: 0.98,
      );

      final detections = matcher.ingest(segment);

      expect(detections, hasLength(1));
      expect(detections.single.score, 1.0);
      expect(detections.single.matchedText, 'i am rich in wisdom');
    });

    test('discarded duplicate tokens cannot join the next repetition', () {
      final first = TranscriptSegment(
        text: "I'm rich in wisdom",
        start: 0.0,
        duration: 1.0,
        isFinal: true,
        confidence: 0.98,
      );
      final duplicate = TranscriptSegment(
        text: "I'm rich in wisdom",
        start: 0.5,
        duration: 1.0,
        isFinal: true,
        confidence: 0.98,
      );
      final next = TranscriptSegment(
        text: "I'm rich in wisdom",
        start: 3.0,
        duration: 1.0,
        isFinal: true,
        confidence: 0.98,
      );

      expect(matcher.ingest(first), hasLength(1));
      expect(matcher.ingest(duplicate), isEmpty);

      final detections = matcher.ingest(next);
      expect(detections, hasLength(1));
      expect(detections.single.audioOffset, const Duration(seconds: 3));
      expect(detections.single.matchedText, 'i am rich in wisdom');
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

    test('counts two long-phrase repetitions in the same final segment', () {
      final longPhrase = const PhraseSpec(
        raw: 'The wisdom of God is at work in me',
        normalisedTokens: [
          'the',
          'wisdom',
          'of',
          'god',
          'is',
          'at',
          'work',
          'in',
          'me',
        ],
      );
      final longPhraseMatcher = PhraseMatcher(target: longPhrase);
      final segment = TranscriptSegment(
        text:
            'the wisdom of god is at work in me the wisdom of god is at work in me',
        start: 1.0,
        duration: 6.0,
        isFinal: true,
        confidence: 0.99,
      );

      final detections = longPhraseMatcher.ingest(segment);

      expect(detections, hasLength(2));
      expect(
        detections.map((d) => d.matchedText),
        everyElement('the wisdom of god is at work in me'),
      );
    });

    group('overlapping transcript streams at a block seam', () {
      test('the same audio heard by both connections counts once', () {
        // A renewal overlaps two Deepgram connections deliberately. Each one
        // numbers its own audio timeline from zero, so the engine tells the
        // matcher where each stream's zero sits on the session timeline: the
        // outgoing connection has been streaming since t=0, the incoming one
        // since t=270.
        matcher.openStream('old');
        matcher.openStream('new', startOffset: const Duration(seconds: 270));

        final fromOld = matcher.ingest(
          finalSegment(testPhrase.raw, start: 272.0),
          streamId: 'old',
        );
        final fromNew = matcher.ingest(
          finalSegment(testPhrase.raw, start: 2.0),
          streamId: 'new',
        );

        expect(fromOld, hasLength(1));
        expect(
          fromNew,
          isEmpty,
          reason: 'both connections transcribed the same repetition',
        );
      });

      test('recogniser jitter between the copies does not double count', () {
        // The rebase is exact — it comes from bytes streamed, not from a clock
        // — but the two recognisers still disagree by tens of milliseconds on
        // where a word starts. What makes the gate hold is that a duplicate's
        // *start* lands near the original's start, and so well before its end.
        matcher.openStream('old');
        matcher.openStream('new', startOffset: const Duration(seconds: 270));

        expect(
          matcher.ingest(
            finalSegment(testPhrase.raw, start: 272.0),
            streamId: 'old',
          ),
          hasLength(1),
        );
        expect(
          matcher.ingest(
            finalSegment(testPhrase.raw, start: 2.15),
            streamId: 'new',
          ),
          isEmpty,
        );
        expect(
          matcher.ingest(
            finalSegment(testPhrase.raw, start: 1.85),
            streamId: 'new',
          ),
          isEmpty,
        );
      });

      test('audio only the new connection heard is still counted', () {
        matcher.openStream('old');
        matcher.openStream('new', startOffset: const Duration(seconds: 270));

        expect(
          matcher.ingest(
            finalSegment(testPhrase.raw, start: 272.0),
            streamId: 'old',
          ),
          hasLength(1),
        );

        // Spoken after the outgoing connection was closed and drained.
        matcher.closeStream('old');
        expect(
          matcher.ingest(
            finalSegment(testPhrase.raw, start: 4.5),
            streamId: 'new',
          ),
          hasLength(1),
        );
      });

      test('a phrase split across the two streams is not a match', () {
        // The windows are per stream precisely so that half a repetition on
        // one connection cannot be completed by half of the *duplicate* on the
        // other, inventing a second count out of audio containing one.
        matcher.openStream('old');
        matcher.openStream('new', startOffset: const Duration(seconds: 270));

        expect(
          matcher.ingest(
            finalSegment('I am rich', start: 272.0),
            streamId: 'old',
          ),
          isEmpty,
        );
        expect(
          matcher.ingest(
            finalSegment('in wisdom', start: 3.0),
            streamId: 'new',
          ),
          isEmpty,
        );
      });

      test('a reconnect keeps counting once its timeline is rebased', () {
        // Regression: a reconnected socket restarts Deepgram's clock at zero.
        // Fed in raw, every later repetition looked like it happened long
        // before the last accepted match and was suppressed for the rest of
        // the session — voice counting stopped dead after the first drop.
        // The engine closes the old id and mints a new one, which is the one
        // mechanism stream identity has.
        matcher.openStream('stream-0');
        expect(
          matcher.ingest(
            finalSegment(testPhrase.raw, start: 100.0),
            streamId: 'stream-0',
          ),
          hasLength(1),
        );

        matcher.closeStream('stream-0');
        matcher.openStream(
          'stream-1',
          startOffset: const Duration(seconds: 120),
        );
        expect(
          matcher.ingest(
            finalSegment(testPhrase.raw, start: 0.5),
            streamId: 'stream-1',
          ),
          hasLength(1),
        );
      });

      test('without the rebase the same reconnect counts nothing', () {
        matcher.openStream('stream-0');
        expect(
          matcher.ingest(
            finalSegment(testPhrase.raw, start: 100.0),
            streamId: 'stream-0',
          ),
          hasLength(1),
        );

        matcher.closeStream('stream-0');
        matcher.openStream('stream-1');
        expect(
          matcher.ingest(
            finalSegment(testPhrase.raw, start: 0.5),
            streamId: 'stream-1',
          ),
          isEmpty,
        );
      });

      test('a stream nobody opened is not counted', () {
        // Offset and window used to live in two maps, so an id with no
        // registered offset still got a window — and was timed against the
        // session's start rather than against wherever its audio began.
        expect(
          matcher.ingest(
            finalSegment(testPhrase.raw, start: 1.0),
            streamId: 'stream-7',
          ),
          isEmpty,
        );
      });

      test('an unnamed stream behaves exactly as it did before', () {
        expect(
          matcher.ingest(finalSegment(testPhrase.raw, start: 1.0)),
          hasLength(1),
        );
        expect(
          matcher.ingest(finalSegment(testPhrase.raw, start: 4.0)),
          hasLength(1),
        );
      });

      test('the unnamed stream is registered, not forgiven', () {
        // It used to open itself inside `ingest`, which made the one id
        // production never sends the only one a typo could not be caught by.
        // The constructor opens it, so it closes like any other.
        matcher.closeStream(PhraseMatcher.defaultStreamId);
        expect(matcher.ingest(finalSegment(testPhrase.raw)), isEmpty);
      });
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

      final result = harness.evaluateFixtureJson(
        jsonPayload,
        fixtureName: 'test_sample',
      );

      expect(result.trueCount, 2);
      expect(result.detectedCount, 2);
      expect(result.recall, 1.0);
      expect(result.passedGate, true);
    });
  });
}
