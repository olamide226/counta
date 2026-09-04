import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/domain/counting/phrase_matcher.dart';
import 'package:counta/domain/counting/transcript_segment.dart';

class FixtureResult {
  final String fixtureName;
  final int trueCount;
  final int detectedCount;
  final double recall;
  final int falsePositives;
  final double falsePositivesPer10Min;
  final double durationMinutes;
  final int transcriptTokenCount;
  final int expectedTokenCount;
  final double transcriptTokenCoverage;

  /// How many repetitions the final transcripts actually contain, estimated
  /// by counting the phrase's most distinctive token. The user pauses during
  /// a session, so `true_count` overstates what the matcher was ever shown.
  final int transcribedRepetitions;

  /// Detections divided by [transcribedRepetitions]: the matcher's own
  /// recall, independent of anything lost before the transcript.
  final double matcherRecall;
  final bool passedGate;

  const FixtureResult({
    required this.fixtureName,
    required this.trueCount,
    required this.detectedCount,
    required this.recall,
    required this.falsePositives,
    required this.falsePositivesPer10Min,
    required this.durationMinutes,
    required this.transcriptTokenCount,
    required this.expectedTokenCount,
    required this.transcriptTokenCoverage,
    required this.transcribedRepetitions,
    required this.matcherRecall,
    required this.passedGate,
  });

  @override
  String toString() {
    return 'FixtureResult($fixtureName: true=$trueCount, transcribed=$transcribedRepetitions, detected=$detectedCount, recall=${(recall * 100).toStringAsFixed(1)}%, matcherRecall=${(matcherRecall * 100).toStringAsFixed(1)}%, transcriptCoverage=${(transcriptTokenCoverage * 100).toStringAsFixed(1)}%, FP/10m=${falsePositivesPer10Min.toStringAsFixed(1)}, Gate=${passedGate ? "PASS" : "FAIL"})';
  }
}

class FixtureReplayHarness {
  final MatcherConfig config;

  FixtureReplayHarness({this.config = const MatcherConfig()});

  /// Replays a JSON fixture through the PhraseMatcher and returns evaluation results.
  FixtureResult evaluateFixtureJson(
    String jsonString, {
    String fixtureName = 'fixture',
  }) {
    final Map<String, dynamic> jsonMap =
        jsonDecode(jsonString) as Map<String, dynamic>;
    final String phraseRaw =
        jsonMap['phrase_raw'] as String? ?? "I'm rich in wisdom";
    final int trueCount = (jsonMap['true_count'] as num?)?.toInt() ?? 100;
    final List<dynamic> segmentsJson =
        jsonMap['segments'] as List<dynamic>? ?? [];

    final tempMatcher = PhraseMatcher(
      target: PhraseSpec(raw: phraseRaw, normalisedTokens: const []),
      config: config,
    );
    final phraseTokens = tempMatcher.normaliseText(phraseRaw);

    final phrase = PhraseSpec(raw: phraseRaw, normalisedTokens: phraseTokens);

    final matcher = PhraseMatcher(target: phrase, config: config);
    int totalDetections = 0;
    int transcriptTokenCount = 0;
    int anchorOccurrences = 0;
    double maxEndSec = 0.0;

    // The longest token is the least likely to be a function word that also
    // appears in surrounding speech ("the", "in", "me").
    final anchorToken = phraseTokens.isEmpty
        ? ''
        : phraseTokens.reduce((a, b) => b.length > a.length ? b : a);

    for (final segJson in segmentsJson) {
      final segment = TranscriptSegment.fromJson(
        segJson as Map<String, dynamic>,
      );
      if (!segment.isFinal) continue;
      final segmentTokens = segment.words.isNotEmpty
          ? segment.words
                .expand((word) => matcher.normaliseText(word.word))
                .toList()
          : matcher.normaliseText(segment.text);
      transcriptTokenCount += segmentTokens.length;
      anchorOccurrences += segmentTokens.where((t) => t == anchorToken).length;

      if (segment.start + segment.duration > maxEndSec) {
        maxEndSec = segment.start + segment.duration;
      }
      final detections = matcher.ingest(segment);
      totalDetections += detections.length;
    }

    final durationMinutes = max(1.0, maxEndSec) / 60.0;
    final recall = trueCount > 0 ? (totalDetections / trueCount) : 0.0;
    final falsePositives = max(0, totalDetections - trueCount);
    final falsePositivesPer10Min = (falsePositives / durationMinutes) * 10.0;
    final matcherRecall = anchorOccurrences > 0
        ? totalDetections / anchorOccurrences
        : 0.0;
    final passedGate = matcherRecall >= 0.95;
    final expectedTokenCount = trueCount * phraseTokens.length;
    final transcriptTokenCoverage = expectedTokenCount > 0
        ? transcriptTokenCount / expectedTokenCount
        : 0.0;

    return FixtureResult(
      fixtureName: fixtureName,
      trueCount: trueCount,
      detectedCount: totalDetections,
      recall: recall,
      falsePositives: falsePositives,
      falsePositivesPer10Min: falsePositivesPer10Min,
      durationMinutes: durationMinutes,
      transcriptTokenCount: transcriptTokenCount,
      expectedTokenCount: expectedTokenCount,
      transcriptTokenCoverage: transcriptTokenCoverage,
      transcribedRepetitions: anchorOccurrences,
      matcherRecall: matcherRecall,
      passedGate: passedGate,
    );
  }

  /// Replays a fixture file from local filesystem.
  Future<FixtureResult> evaluateFixtureFile(File file) async {
    final jsonString = await file.readAsString();
    final name = file.path.split('/').last.replaceAll('.json', '');
    return evaluateFixtureJson(jsonString, fixtureName: name);
  }
}
