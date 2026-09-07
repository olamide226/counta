import 'package:flutter_test/flutter_test.dart';
import 'package:counta/domain/counting/transcript_segment.dart';

void main() {
  group('TranscriptSegment', () {
    test(
      'fromDeepgramJson correctly parses Nova-3 websocket result payload',
      () {
        final jsonPayload = {
          'type': 'Results',
          'is_final': true,
          'speech_final': true,
          'start': 1.25,
          'duration': 2.10,
          'channel': {
            'alternatives': [
              {
                'transcript': "I'm rich in wisdom",
                'confidence': 0.985,
                'words': [
                  {
                    'word': "i'm",
                    'start': 1.25,
                    'end': 1.50,
                    'confidence': 0.99,
                  },
                  {
                    'word': 'rich',
                    'start': 1.55,
                    'end': 1.85,
                    'confidence': 0.98,
                  },
                  {
                    'word': 'in',
                    'start': 1.90,
                    'end': 2.05,
                    'confidence': 0.97,
                  },
                  {
                    'word': 'wisdom',
                    'start': 2.10,
                    'end': 2.65,
                    'confidence': 0.99,
                  },
                ],
              },
            ],
          },
        };

        final segment = TranscriptSegment.fromDeepgramJson(jsonPayload);

        expect(segment.text, "I'm rich in wisdom");
        expect(segment.isFinal, true);
        expect(segment.speechFinal, true);
        expect(segment.start, 1.25);
        expect(segment.duration, 2.10);
        expect(segment.confidence, 0.985);
        expect(segment.words.length, 4);
        expect(segment.words[0].word, "i'm");
        expect(segment.words[3].word, "wisdom");
      },
    );

    test('toJson and fromJson round-trip serialisation works', () {
      final original = TranscriptSegment(
        text: 'hello world',
        start: 0.5,
        duration: 1.0,
        isFinal: true,
        confidence: 0.95,
        words: const [
          TranscriptWord(word: 'hello', start: 0.5, end: 0.9, confidence: 0.96),
          TranscriptWord(word: 'world', start: 1.0, end: 1.5, confidence: 0.94),
        ],
      );

      final jsonMap = original.toJson();
      final restored = TranscriptSegment.fromJson(jsonMap);

      expect(restored.text, original.text);
      expect(restored.start, original.start);
      expect(restored.duration, original.duration);
      expect(restored.isFinal, original.isFinal);
      expect(restored.confidence, original.confidence);
      expect(restored.words.length, 2);
      expect(restored.words[0].word, 'hello');
      expect(restored.words[1].word, 'world');
    });
  });
}
