import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/domain/counting/phrase_matcher.dart';
import 'package:counta/domain/counting/phrase_normaliser.dart';
import 'package:counta/domain/counting/transcript_segment.dart';

/// One phrase's share of a fixture replay.
///
/// Only meaningful split out when a fixture was recorded with several phrases;
/// a single-phrase fixture has exactly one of these and it equals the totals.
class PhraseResult {
  final String phrase;

  /// How many times the speaker said this phrase, when the fixture recorded
  /// per-phrase counts. Null when only a session total was given.
  final int? trueCount;

  final int detectedCount;

  /// Estimate of how many repetitions of this phrase the final transcripts
  /// actually contain: the median occurrence count across [trackedWords].
  final int transcribedRepetitions;

  /// The words this phrase is counted by — its own, not shared with another
  /// phrase in the set.
  final List<String> trackedWords;

  /// True when every word of this phrase also appears in another phrase of
  /// the set, so no word identifies it alone and [transcribedRepetitions]
  /// counts the other phrase's repetitions too. Read its matcher recall as
  /// approximate.
  final bool anchorShared;

  const PhraseResult({
    required this.phrase,
    required this.trueCount,
    required this.detectedCount,
    required this.transcribedRepetitions,
    required this.trackedWords,
    required this.anchorShared,
  });

  double get matcherRecall =>
      transcribedRepetitions > 0 ? detectedCount / transcribedRepetitions : 0.0;
}

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

  /// The fixture's own phrases, in recorded order.
  final List<PhraseResult> phrases;

  /// Detections claimed by `extraPhrases` passed to the replay — phrases the
  /// speaker never said. Always zero outside the cross-talk gate, and any
  /// non-zero value there is a false positive by definition.
  final int distractorDetections;

  bool get isMultiPhrase => phrases.length > 1;

  /// Whether this fixture is large enough for its recall to be held to a gate.
  bool get isGateable =>
      transcribedRepetitions >= FixtureReplayHarness.minGatedRepetitions;

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
    required this.phrases,
    this.distractorDetections = 0,
  });

  @override
  String toString() {
    return 'FixtureResult($fixtureName: true=$trueCount, transcribed=$transcribedRepetitions, detected=$detectedCount, recall=${(recall * 100).toStringAsFixed(1)}%, matcherRecall=${(matcherRecall * 100).toStringAsFixed(1)}%, transcriptCoverage=${(transcriptTokenCoverage * 100).toStringAsFixed(1)}%, FP/10m=${falsePositivesPer10Min.toStringAsFixed(1)}, Gate=${passedGate ? "PASS" : "FAIL"})';
  }
}

class FixtureReplayHarness {
  final MatcherConfig config;

  /// Fewest transcribed repetitions a fixture needs before its recall can
  /// fail a gate.
  ///
  /// A percentage over a handful of repetitions measures the recording, not
  /// the matcher. normal_30 holds 28: Deepgram heard "anointing" as
  /// "nineteen" through one stretch, the matcher rightly refused two
  /// repetitions that had no phrase left in them, and that alone is 7 points.
  /// At 100, one miss is one point and a 95% bar means something. Smaller
  /// fixtures are still replayed and printed.
  static const int minGatedRepetitions = 100;

  FixtureReplayHarness({this.config = const MatcherConfig()});

  /// Replays a JSON fixture through the PhraseMatcher and returns evaluation results.
  /// Replays a fixture, optionally with [extraPhrases] listening alongside
  /// the fixture's own phrase.
  ///
  /// The extra phrases exist to prove a negative: adding a phrase the audio
  /// never contains must not change what the real phrase counts. That is the
  /// whole risk of a multi-phrase session, and it cannot be shown on a
  /// hand-written segment or two.
  FixtureResult evaluateFixtureJson(
    String jsonString, {
    String fixtureName = 'fixture',
    List<String> extraPhrases = const [],
  }) {
    final Map<String, dynamic> jsonMap =
        jsonDecode(jsonString) as Map<String, dynamic>;
    final List<dynamic> segmentsJson =
        jsonMap['segments'] as List<dynamic>? ?? [];

    final normalise = PhraseNormaliser(
      homophones: config.homophones,
      contractions: config.contractions,
    );

    // `phrases_raw` is written by multi-phrase recordings; older fixtures
    // only have `phrase_raw`, which is also still written as the first
    // phrase so a single-phrase reader never sees a missing field.
    final rawPhrases = <String>[
      for (final phrase in jsonMap['phrases_raw'] as List? ?? const [])
        if (phrase is String && phrase.trim().isNotEmpty) phrase,
    ];
    if (rawPhrases.isEmpty) {
      rawPhrases.add(jsonMap['phrase_raw'] as String? ?? "I'm rich in wisdom");
    }

    final ownSpecs = [
      for (final raw in rawPhrases)
        PhraseSpec(raw: raw, normalisedTokens: normalise(raw)),
    ];
    final ownKeys = {
      for (final spec in ownSpecs) spec.normalisedTokens.join(' '),
    };

    // Per-phrase true counts, aligned with `phrases_raw`, when the speaker
    // recorded them. Ignored unless there is exactly one per phrase: a
    // misaligned list would attribute counts to the wrong phrase.
    final recordedCounts = [
      for (final count in jsonMap['true_counts'] as List? ?? const [])
        if (count is num) count.toInt(),
    ];
    final perPhraseTrue = recordedCounts.length == ownSpecs.length
        ? recordedCounts
        : null;
    final int trueCount =
        (jsonMap['true_count'] as num?)?.toInt() ??
        perPhraseTrue?.fold<int>(0, (sum, c) => sum + c) ??
        100;

    // An extra phrase that normalises to one of the fixture's own is not an
    // extra phrase, and the app's validator refuses one — so the harness must
    // not quietly build a set the app could never produce.
    final extraSpecs = [
      for (final extra in extraPhrases)
        if (!ownKeys.contains(normalise(extra).join(' ')))
          PhraseSpec(raw: extra, normalisedTokens: normalise(extra)),
    ];

    final matcher = PhraseMatcher(
      target: PhraseSet([...ownSpecs, ...extraSpecs]),
      config: config,
    );

    // The words each phrase is tracked by: the ones no other phrase in the
    // set uses, so "wisdom" in two phrases is not counted as two repetitions
    // of each. A phrase with no word of its own — one contained in another —
    // falls back to all its words and is flagged, because its transcribed
    // count then includes the other phrase's repetitions.
    final trackedWords = <({List<String> words, bool shared})>[];
    for (int i = 0; i < ownSpecs.length; i++) {
      final tokens = ownSpecs[i].normalisedTokens;
      final elsewhere = {
        for (int j = 0; j < ownSpecs.length; j++)
          if (j != i) ...ownSpecs[j].normalisedTokens,
      };
      final unique = tokens.where((t) => !elsewhere.contains(t)).toList();
      trackedWords.add((
        words: unique.isNotEmpty ? unique : tokens,
        shared: unique.isEmpty,
      ));
    }

    final indexByRaw = {
      for (int i = 0; i < ownSpecs.length; i++) ownSpecs[i].raw: i,
    };
    final detectedByPhrase = List<int>.filled(ownSpecs.length, 0);
    final occurrencesByToken = <String, int>{};
    int totalDetections = 0;
    int distractorDetections = 0;
    int transcriptTokenCount = 0;
    double maxEndSec = 0.0;

    for (final segJson in segmentsJson) {
      final segment = TranscriptSegment.fromJson(
        segJson as Map<String, dynamic>,
      );
      if (!segment.isFinal) continue;
      final segmentTokens = segment.words.isNotEmpty
          ? segment.words.expand((word) => normalise(word.word)).toList()
          : normalise(segment.text);
      transcriptTokenCount += segmentTokens.length;
      for (final token in segmentTokens) {
        occurrencesByToken.update(token, (n) => n + 1, ifAbsent: () => 1);
      }

      if (segment.start + segment.duration > maxEndSec) {
        maxEndSec = segment.start + segment.duration;
      }
      for (final detection in matcher.ingest(segment)) {
        totalDetections++;
        final index = indexByRaw[detection.phrase.raw];
        if (index == null) {
          distractorDetections++;
        } else {
          detectedByPhrase[index]++;
        }
      }
    }

    final transcribedByPhrase = [
      for (final tracked in trackedWords)
        _transcribedRepetitions(tracked.words, occurrencesByToken),
    ];

    final phrases = [
      for (int i = 0; i < ownSpecs.length; i++)
        PhraseResult(
          phrase: ownSpecs[i].raw,
          trueCount: perPhraseTrue?[i],
          detectedCount: detectedByPhrase[i],
          transcribedRepetitions: transcribedByPhrase[i],
          trackedWords: trackedWords[i].words,
          anchorShared: trackedWords[i].shared,
        ),
    ];

    // A phrase whose words are all shared was estimated from the same words
    // as the phrase containing it, so adding it in would count those
    // repetitions twice. Only phrases with words of their own contribute,
    // unless no phrase has any.
    final independent = [
      for (int i = 0; i < ownSpecs.length; i++)
        if (!trackedWords[i].shared) transcribedByPhrase[i],
    ];
    final transcribedRepetitions =
        (independent.isNotEmpty ? independent : transcribedByPhrase).fold<int>(
          0,
          (sum, n) => sum + n,
        );
    final ownDetections = totalDetections - distractorDetections;

    final durationMinutes = max(1.0, maxEndSec) / 60.0;
    final recall = trueCount > 0 ? (totalDetections / trueCount) : 0.0;
    final falsePositives = max(0, totalDetections - trueCount);
    final falsePositivesPer10Min = (falsePositives / durationMinutes) * 10.0;
    final matcherRecall = transcribedRepetitions > 0
        ? ownDetections / transcribedRepetitions
        : 0.0;
    final passedGate = matcherRecall >= 0.95;

    // What a perfect transcript would hold. With per-phrase counts this is
    // exact; with only a total, each repetition is taken as a phrase of
    // average length.
    final expectedTokenCount = perPhraseTrue != null
        ? [
            for (int i = 0; i < ownSpecs.length; i++)
              perPhraseTrue[i] * ownSpecs[i].normalisedTokens.length,
          ].fold<int>(0, (sum, n) => sum + n)
        : (trueCount *
                  ownSpecs.fold<int>(
                    0,
                    (sum, s) => sum + s.normalisedTokens.length,
                  ) /
                  ownSpecs.length)
              .round();
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
      transcribedRepetitions: transcribedRepetitions,
      matcherRecall: matcherRecall,
      passedGate: passedGate,
      phrases: phrases,
      distractorDetections: distractorDetections,
    );
  }

  /// How many repetitions of a phrase the transcript contains, judged by
  /// the median count of [words] across it.
  ///
  /// This used to count one word — the phrase's longest — and trusted it to be
  /// transcribed every time. It was not: in normal_30 the longest word was the
  /// speaker's own spelling "annointing", which the transcript held 9 times
  /// against 16 for the correct "anointing", so 26 detections read as 289%
  /// recall and a broken number passed the gate.
  ///
  /// A median over every word cannot be moved by one misheard word or by one
  /// function word that also turns up in surrounding chatter, and each word
  /// also counts its near-spellings, so "received" is a "receive".
  static int _transcribedRepetitions(
    List<String> words,
    Map<String, int> occurrences,
  ) {
    if (words.isEmpty) return 0;
    final counts = [
      for (final word in words)
        occurrences.entries
            .where((entry) => _sameSpokenWord(entry.key, word))
            .fold<int>(0, (sum, entry) => sum + entry.value),
    ]..sort();
    final middle = counts.length ~/ 2;
    return counts.length.isOdd
        ? counts[middle]
        : ((counts[middle - 1] + counts[middle]) / 2).round();
  }

  /// Whether a transcribed word is the same spoken word as [target].
  ///
  /// Short words must match exactly — "in" and "is" differ by one letter and
  /// are not the same word. Longer ones may differ by a character or so,
  /// which covers spelling variants and tense ("anointing", "received")
  /// without letting "god" stand in for "good".
  static bool _sameSpokenWord(String heard, String target) {
    if (heard == target) return true;
    if (heard.length < 4 || target.length < 4) return false;
    final distance = _levenshtein(heard, target);
    return 1.0 - distance / max(heard.length, target.length) >= 0.8;
  }

  static int _levenshtein(String a, String b) {
    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (int i = 1; i <= a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (int j = 1; j <= b.length; j++) {
        current[j] = min(
          min(previous[j] + 1, current[j - 1] + 1),
          previous[j - 1] +
              (a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1),
        );
      }
      previous = current;
    }
    return previous[b.length];
  }

  /// Replays a fixture file from local filesystem.
  Future<FixtureResult> evaluateFixtureFile(File file) async {
    final jsonString = await file.readAsString();
    final name = file.path.split('/').last.replaceAll('.json', '');
    return evaluateFixtureJson(jsonString, fixtureName: name);
  }
}
