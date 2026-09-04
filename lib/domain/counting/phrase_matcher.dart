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

  /// Lower similarity accepted for a candidate whose head and tail match the
  /// target exactly. Real transcripts garble the *middle* of a repetition far
  /// more often than its ends ("the wisdom of god is how to walk in me"), and
  /// a slice bracketed by the target's own opening and closing words is far
  /// more likely a mangled repetition than unrelated speech. Set equal to
  /// [threshold] to disable.
  final double anchoredThreshold;
  final double refractoryMultiplier;
  final int refractoryFloorMs;
  final double windowSlack;
  final Map<String, String> homophones;
  final Map<String, String> contractions;

  const MatcherConfig({
    this.threshold = 0.80,
    this.anchoredThreshold = 0.65,
    this.refractoryMultiplier = 0.0,
    this.refractoryFloorMs = 0,
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

class _MatchCandidate {
  final int startIndex;
  final int length;
  final double score;

  const _MatchCandidate({
    required this.startIndex,
    required this.length,
    required this.score,
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

  PhraseMatcher({required this.target, this.config = const MatcherConfig()});

  MatcherStats get stats => MatcherStats(
    detectionsCount: _detectionsCount,
    windowsEvaluated: _windowsEvaluated,
    medianUtteranceMs: _calculateMedianUtteranceMs(),
  );

  late final PhraseNormaliser _normaliser = PhraseNormaliser(
    homophones: config.homophones,
    contractions: config.contractions,
  );

  late final List<String> _normalisedTarget = List.unmodifiable(
    target.normalisedTokens.isNotEmpty
        ? target.normalisedTokens
        : normaliseText(target.raw),
  );

  /// Normalises a string using the config contraction, homophone, punctuation, and lowercase rules.
  List<String> normaliseText(String text) => _normaliser(text);

  /// Calculates token-level Levenshtein similarity ratio in [0, 1].
  ///
  /// A substitution between two tokens that are themselves similar at the
  /// character level ("working" for "work", "gods" for "god") costs less than
  /// a full edit, so inflected or lightly misheard words are not punished as
  /// hard as unrelated ones.
  double calculateTokenSimilarity(
    List<String> candidate,
    List<String> targetTokens,
  ) {
    if (candidate.isEmpty && targetTokens.isEmpty) return 1.0;
    if (candidate.isEmpty || targetTokens.isEmpty) return 0.0;

    final distance = _levenshteinDistance(candidate, targetTokens);
    final maxLen = max(candidate.length, targetTokens.length);
    return 1.0 - (distance / maxLen);
  }

  double _levenshteinDistance(List<String> a, List<String> b) {
    final m = a.length;
    final n = b.length;
    var previous = List<double>.generate(n + 1, (index) => index.toDouble());
    var current = List<double>.filled(n + 1, 0);

    for (int i = 1; i <= m; i++) {
      current[0] = i.toDouble();
      for (int j = 1; j <= n; j++) {
        final cost = _substitutionCost(a[i - 1], b[j - 1]);
        current[j] = min(
          min(previous[j] + 1, current[j - 1] + 1),
          previous[j - 1] + cost,
        );
      }

      final swap = previous;
      previous = current;
      current = swap;
    }
    return previous[n];
  }

  /// Tokens this short are too easy to confuse ("in"/"is"/"it") for character
  /// overlap to mean anything, so they only ever match exactly.
  static const int _minFuzzyTokenLength = 3;

  /// Below this character similarity two tokens are treated as unrelated.
  static const double _minFuzzyTokenSimilarity = 0.5;

  double _substitutionCost(String a, String b) {
    if (a == b) return 0.0;
    if (a.length < _minFuzzyTokenLength || b.length < _minFuzzyTokenLength) {
      return 1.0;
    }
    final similarity = 1.0 - _charLevenshtein(a, b) / max(a.length, b.length);
    return similarity >= _minFuzzyTokenSimilarity ? 1.0 - similarity : 1.0;
  }

  static int _charLevenshtein(String a, String b) {
    final m = a.length;
    final n = b.length;
    var previous = List<int>.generate(n + 1, (index) => index);
    var current = List<int>.filled(n + 1, 0);
    for (int i = 1; i <= m; i++) {
      current[0] = i;
      for (int j = 1; j <= n; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        current[j] = min(
          min(previous[j] + 1, current[j - 1] + 1),
          previous[j - 1] + cost,
        );
      }
      final swap = previous;
      previous = current;
      current = swap;
    }
    return previous[n];
  }

  /// How many leading target tokens a candidate must reproduce exactly to
  /// count as anchored. Anchoring needs at least four target tokens so that
  /// the head and tail leave a middle for the relaxation to apply to.
  static const int _minAnchoredTargetLength = 4;

  int get _headAnchorLength => max(2, _normalisedTarget.length ~/ 3);

  bool _isAnchored(List<String> candidate) {
    final target = _normalisedTarget;
    if (target.length < _minAnchoredTargetLength) return false;
    final head = _headAnchorLength;
    if (candidate.length <= head) return false;
    for (int i = 0; i < head; i++) {
      if (candidate[i] != target[i]) return false;
    }
    return candidate.last == target.last;
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
    final normalisedTarget = _normalisedTarget;

    if (normalisedTarget.isEmpty) return [];

    // Parse words/tokens from segment
    List<TokenWithOffset> newTokens = [];
    if (segment.words.isNotEmpty) {
      for (final w in segment.words) {
        final normWords = normaliseText(w.word);
        for (final nw in normWords) {
          newTokens.add(
            TokenWithOffset(token: nw, startSec: w.start, endSec: w.end),
          );
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
        newTokens.add(
          TokenWithOffset(
            token: normWords[i],
            startSec: startSec,
            endSec: endSec,
          ),
        );
      }
    }

    _window.addAll(newTokens);

    // Evaluate candidate slices and choose the closest match. Searching by
    // length alone let a target plus one noise word beat an exact target.
    final targetLen = normalisedTarget.length;
    final minSliceLen = max(1, (targetLen * 0.7).floor());
    final maxSliceLen = (targetLen * config.windowSlack).ceil();
    final maxRetainedWindowLen = maxSliceLen + 3;

    while (_window.isNotEmpty) {
      _MatchCandidate? best;

      for (
        int sliceLen = min(maxSliceLen, _window.length);
        sliceLen >= minSliceLen;
        sliceLen--
      ) {
        for (
          int startIdx = 0;
          startIdx <= _window.length - sliceLen;
          startIdx++
        ) {
          _windowsEvaluated++;
          final candidateTokens = _window.sublist(
            startIdx,
            startIdx + sliceLen,
          );
          final candidateStringList = candidateTokens
              .map((t) => t.token)
              .toList();

          final similarity = calculateTokenSimilarity(
            candidateStringList,
            normalisedTarget,
          );

          final threshold = _isAnchored(candidateStringList)
              ? min(config.threshold, config.anchoredThreshold)
              : config.threshold;
          if (similarity < threshold) continue;

          final candidate = _MatchCandidate(
            startIndex: startIdx,
            length: sliceLen,
            score: similarity,
          );
          if (_isBetterCandidate(candidate, best, targetLen)) {
            best = candidate;
          }
        }
      }

      if (best == null) break;

      final candidateTokens = _window.sublist(
        best.startIndex,
        best.startIndex + best.length,
      );
      final candidateStartMs = candidateTokens.first.startSec * 1000.0;
      final candidateEndMs = candidateTokens.last.endSec * 1000.0;
      final utteranceDurationMs = max(100.0, candidateEndMs - candidateStartMs);

      if (_lastMatchEndMs != null) {
        final elapsedSinceLastMatch = candidateStartMs - _lastMatchEndMs!;
        if (elapsedSinceLastMatch < currentRefractoryMs) {
          // This candidate is a duplicate. Retire its tokens so they cannot
          // join the next real repetition and create a cross-boundary match.
          _window.removeRange(0, best.startIndex + best.length);
          continue;
        }
      }

      _detectionsCount++;
      _lastMatchEndMs = candidateEndMs;
      if (best.length == targetLen) {
        _observeUtterance(utteranceDurationMs);
      }

      final matchedText = candidateTokens.map((t) => t.token).join(' ');
      final audioOffset = Duration(milliseconds: candidateStartMs.round());

      detections.add(
        Detection(
          score: best.score,
          audioOffset: audioOffset,
          matchedText: matchedText,
        ),
      );

      _window.removeRange(0, best.startIndex + best.length);
    }

    // Retain only enough unmatched context to bridge a phrase split across
    // adjacent final segments. This must happen after scanning the newly
    // arrived segment, otherwise a long phrase repeated twice in one segment
    // can be truncated before either repetition is counted.
    if (_window.length > maxRetainedWindowLen) {
      _window.removeRange(0, _window.length - maxRetainedWindowLen);
    }

    return detections;
  }

  bool _isBetterCandidate(
    _MatchCandidate candidate,
    _MatchCandidate? current,
    int targetLen,
  ) {
    if (current == null) return true;
    if (candidate.score != current.score) {
      return candidate.score > current.score;
    }

    final candidateLengthDifference = (candidate.length - targetLen).abs();
    final currentLengthDifference = (current.length - targetLen).abs();
    if (candidateLengthDifference != currentLengthDifference) {
      return candidateLengthDifference < currentLengthDifference;
    }

    return candidate.startIndex < current.startIndex;
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
