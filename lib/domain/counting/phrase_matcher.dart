import 'dart:math';

import 'counting_engine.dart';
import 'phrase_normaliser.dart';
import 'transcript_segment.dart';

class Detection {
  final double score;
  final Duration audioOffset;
  final String matchedText;
  final DateTime detectedAt;

  Detection({
    required this.score,
    required this.audioOffset,
    required this.matchedText,
    DateTime? detectedAt,
  }) : detectedAt = detectedAt ?? DateTime.now();

  @override
  String toString() =>
      'Detection(score: ${score.toStringAsFixed(2)}, offset: $audioOffset, text: "$matchedText")';
}

class MatcherConfig {
  final double threshold;
  final double refractoryMultiplier;
  final int refractoryFloorMs;
  final double windowSlack;
  final Map<String, String> homophones;
  final Map<String, String> contractions;

  const MatcherConfig({
    this.threshold = 0.80,
    this.refractoryMultiplier = 0.60,
    this.refractoryFloorMs = 1200,
    this.windowSlack = 1.5,
    this.homophones = PhraseNormaliser.defaultHomophones,
    this.contractions = PhraseNormaliser.defaultContractions,
  });
}

class TokenWithOffset {
  final String token;
  final double startSec;
  final double endSec;

  TokenWithOffset({
    required this.token,
    required this.startSec,
    required this.endSec,
  });
}

class MatcherStats {
  final int detectionsCount;
  final int windowsEvaluated;
  final double medianUtteranceMs;

  const MatcherStats({
    required this.detectionsCount,
    required this.windowsEvaluated,
    required this.medianUtteranceMs,
  });
}

class PhraseMatcher {
  final PhraseSpec target;
  final MatcherConfig config;

  final List<TokenWithOffset> _window = [];
  final List<double> _observedUtteranceDurationsMs = [];

  int _windowsEvaluated = 0;
  int _detectionsCount = 0;
  double? _lastMatchEndMs;

  PhraseMatcher({
    required this.target,
    this.config = const MatcherConfig(),
  });

  MatcherStats get stats => MatcherStats(
        detectionsCount: _detectionsCount,
        windowsEvaluated: _windowsEvaluated,
        medianUtteranceMs: _calculateMedianUtteranceMs(),
      );

  late final PhraseNormaliser _normaliser = PhraseNormaliser(
    homophones: config.homophones,
    contractions: config.contractions,
  );

  /// Normalises a string using the config contraction, homophone, punctuation, and lowercase rules.
  List<String> normaliseText(String text) => _normaliser(text);

  /// Calculates token-level Levenshtein similarity ratio in [0, 1].
  double calculateTokenSimilarity(
      List<String> candidate, List<String> targetTokens) {
    if (candidate.isEmpty && targetTokens.isEmpty) return 1.0;
    if (candidate.isEmpty || targetTokens.isEmpty) return 0.0;

    final distance = _levenshteinDistance(candidate, targetTokens);
    final maxLen = max(candidate.length, targetTokens.length);
    return 1.0 - (distance / maxLen);
  }

  int _levenshteinDistance(List<String> a, List<String> b) {
    final m = a.length;
    final n = b.length;
    final dp = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0));

    for (int i = 0; i <= m; i++) dp[i][0] = i;
    for (int j = 0; j <= n; j++) dp[0][j] = j;

    for (int i = 1; i <= m; i++) {
      for (int j = 1; j <= n; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        dp[i][j] = min(
          min(dp[i - 1][j] + 1, dp[i][j - 1] + 1),
          dp[i - 1][j - 1] + cost,
        );
      }
    }
    return dp[m][n];
  }

  /// Calculates current adaptive refractory period in milliseconds.
  double get currentRefractoryMs {
    final floor = config.refractoryFloorMs.toDouble();
    if (_observedUtteranceDurationsMs.length < 5) {
      return floor;
    }
    final median = _calculateMedianUtteranceMs();
    final calculated = median * config.refractoryMultiplier;
    return max(floor, calculated);
  }

  /// Memoised median, invalidated whenever a new observation lands.
  ///
  /// This is read inside the candidate-slice scan, so recomputing a full
  /// copy-and-sort each time made per-detection cost grow linearly with
  /// session length — precisely the wrong shape for hour-long sessions.
  double? _cachedMedianMs;

  double _calculateMedianUtteranceMs() {
    final cached = _cachedMedianMs;
    if (cached != null) return cached;

    if (_observedUtteranceDurationsMs.isEmpty) {
      return config.refractoryFloorMs.toDouble();
    }
    final sorted = List<double>.from(_observedUtteranceDurationsMs)..sort();
    final middle = sorted.length ~/ 2;
    final median = sorted.length.isOdd
        ? sorted[middle]
        : (sorted[middle - 1] + sorted[middle]) / 2.0;

    return _cachedMedianMs = median;
  }

  /// Records an utterance length for the adaptive refractory period.
  ///
  /// Bounded to the most recent [_maxObservedUtterances]: the refractory is
  /// meant to adapt to the user's *current* pace, and a median over two hours
  /// of history stops adapting at all.
  void _observeUtterance(double durationMs) {
    _observedUtteranceDurationsMs.add(durationMs);
    if (_observedUtteranceDurationsMs.length > _maxObservedUtterances) {
      _observedUtteranceDurationsMs.removeAt(0);
    }
    _cachedMedianMs = null;
  }

  static const int _maxObservedUtterances = 50;

  /// Ingests a finalised transcript segment and returns accepted detections.
  List<Detection> ingest(TranscriptSegment segment) {
    // Requirements 8.5: Count only on finalised segments
    if (!segment.isFinal) return [];

    final detections = <Detection>[];
    final normalisedTarget = target.normalisedTokens.isNotEmpty
        ? target.normalisedTokens
        : normaliseText(target.raw);

    if (normalisedTarget.isEmpty) return [];

    // Parse words/tokens from segment
    List<TokenWithOffset> newTokens = [];
    if (segment.words.isNotEmpty) {
      for (final w in segment.words) {
        final normWords = normaliseText(w.word);
        for (final nw in normWords) {
          newTokens.add(TokenWithOffset(
            token: nw,
            startSec: w.start,
            endSec: w.end,
          ));
        }
      }
    } else {
      final normWords = normaliseText(segment.text);
      final durationPerToken = normWords.isNotEmpty
          ? (segment.duration / normWords.length)
          : 0.0;
      for (int i = 0; i < normWords.length; i++) {
        final startSec = segment.start + (i * durationPerToken);
        final endSec = startSec + durationPerToken;
        newTokens.add(TokenWithOffset(
          token: normWords[i],
          startSec: startSec,
          endSec: endSec,
        ));
      }
    }

    _window.addAll(newTokens);

    // Limit window size using windowSlack
    final maxWindowLen = (normalisedTarget.length * config.windowSlack).ceil() + 3;
    if (_window.length > maxWindowLen) {
      _window.removeRange(0, _window.length - maxWindowLen);
    }

    // Evaluate sliding window candidate slices, longest first
    final targetLen = normalisedTarget.length;
    final minSliceLen = max(1, (targetLen * 0.7).floor());
    final maxSliceLen = (targetLen * config.windowSlack).ceil();

    bool matchedInPass = false;
    do {
      matchedInPass = false;

      for (int sliceLen = min(maxSliceLen, _window.length);
          sliceLen >= minSliceLen;
          sliceLen--) {
        for (int startIdx = 0; startIdx <= _window.length - sliceLen; startIdx++) {
          _windowsEvaluated++;
          final candidateTokens =
              _window.sublist(startIdx, startIdx + sliceLen);
          final candidateStringList = candidateTokens.map((t) => t.token).toList();

          final similarity =
              calculateTokenSimilarity(candidateStringList, normalisedTarget);

          if (similarity >= config.threshold) {
            final candidateStartMs = candidateTokens.first.startSec * 1000.0;
            final candidateEndMs = candidateTokens.last.endSec * 1000.0;
            final utteranceDurationMs = max(100.0, candidateEndMs - candidateStartMs);

            // Refractory suppression check
            if (_lastMatchEndMs != null) {
              final elapsedSinceLastMatch = candidateStartMs - _lastMatchEndMs!;
              if (elapsedSinceLastMatch < currentRefractoryMs) {
                // Suppress match due to refractory period
                continue;
              }
            }

            // Accepted match
            _detectionsCount++;
            _lastMatchEndMs = candidateEndMs;
            _observeUtterance(utteranceDurationMs);

            final matchedText = candidateStringList.join(' ');
            final audioOffset = Duration(milliseconds: candidateStartMs.round());

            detections.add(Detection(
              score: similarity,
              audioOffset: audioOffset,
              matchedText: matchedText,
            ));

            // Token consumption: remove matched tokens from window
            _window.removeRange(0, startIdx + sliceLen);
            matchedInPass = true;
            break;
          }
        }
        if (matchedInPass) break;
      }
    } while (matchedInPass && _window.isNotEmpty);

    return detections;
  }

  void reset() {
    _window.clear();
    _observedUtteranceDurationsMs.clear();
    _cachedMedianMs = null;
    _windowsEvaluated = 0;
    _detectionsCount = 0;
    _lastMatchEndMs = null;
  }
}
