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

/// One transcript stream: its token window, and where its zero sits on the
/// session timeline.
///
/// A stream is one Deepgram *connection*, not one session: every connect
/// starts a fresh audio timeline at zero, and a block renewal deliberately
/// runs two connections at once. Interleaving two connections' tokens into a
/// single ordered window produces slices that span both and matches that
/// exist in neither, so each stream gets its own window and they are only
/// ever compared through the shared acceptance gate.
class _StreamWindow {
  _StreamWindow(this.offsetMs);

  /// Offset of this stream's zero on the session timeline, in ms. The engine
  /// knows this exactly — it is the audio it had already streamed when the
  /// connection received its first frame.
  final double offsetMs;

  final List<TokenWithOffset> tokens = [];
}

class PhraseMatcher {
  final PhraseSpec target;
  final MatcherConfig config;

  /// The open streams. Offset and tokens travel together: as two maps keyed
  /// by stream id they could disagree, and an id nobody had opened silently
  /// picked up a window at offset zero.
  final Map<String, _StreamWindow> _streams = {};

  final List<double> _observedUtteranceDurationsMs = [];

  int _windowsEvaluated = 0;
  int _detectionsCount = 0;
  double? _lastMatchEndMs;

  PhraseMatcher({required this.target, this.config = const MatcherConfig()}) {
    openStream(defaultStreamId);
  }

  /// Stream id used when a caller does not name one — a session with a single
  /// connection, and every fixture replay.
  ///
  /// Opened by the constructor, so it is an ordinary registered stream sitting
  /// at session zero rather than a case [ingest] has to forgive. It used to
  /// open itself on first use, which meant the one id production never sends
  /// was the only one a typo could not be caught by.
  static const String defaultStreamId = 'default';

  /// Registers a transcript stream and where its zero sits on the session
  /// timeline.
  ///
  /// The only way a stream comes into existence: [ingest] ignores an id
  /// nobody opened. A reconnect reuses the socket but not its timeline, so
  /// the engine closes that connection's id and opens a fresh one rather than
  /// reopening the same one — one mechanism for stream identity, not two.
  void openStream(String streamId, {Duration startOffset = Duration.zero}) {
    _streams[streamId] = _StreamWindow(startOffset.inMicroseconds / 1000.0);
  }

  /// Forgets a stream once its connection is closed and drained.
  void closeStream(String streamId) => _streams.remove(streamId);

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
  ///
  /// [streamId] names the connection the segment came from. Its offsets are
  /// rebased onto the session timeline with the offset given to [openStream],
  /// which is what lets two overlapping connections — and everything after a
  /// reconnect — be compared against the same acceptance gate. A segment on an
  /// id nobody opened is dropped.
  List<Detection> ingest(
    TranscriptSegment segment, {
    String streamId = defaultStreamId,
  }) {
    // Requirements 8.5: Count only on finalised segments
    if (!segment.isFinal) return [];

    final detections = <Detection>[];
    final normalisedTarget = _normalisedTarget;

    if (normalisedTarget.isEmpty) return [];

    // One rule for every id, [defaultStreamId] included: a stream nobody
    // opened has no place on the session timeline, so nothing said on it can
    // be positioned on one.
    final stream = _streams[streamId];
    if (stream == null) return [];

    final offsetSec = stream.offsetMs / 1000.0;
    final window = stream.tokens;

    // Parse words/tokens from segment
    List<TokenWithOffset> newTokens = [];
    if (segment.words.isNotEmpty) {
      for (final w in segment.words) {
        final normWords = normaliseText(w.word);
        for (final nw in normWords) {
          newTokens.add(
            TokenWithOffset(
              token: nw,
              startSec: w.start + offsetSec,
              endSec: w.end + offsetSec,
            ),
          );
        }
      }
    } else {
      final normWords = normaliseText(segment.text);
      final durationPerToken = normWords.isNotEmpty
          ? (segment.duration / normWords.length)
          : 0.0;
      for (int i = 0; i < normWords.length; i++) {
        final startSec = segment.start + offsetSec + (i * durationPerToken);
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

    window.addAll(newTokens);

    // Evaluate candidate slices and choose the closest match. Searching by
    // length alone let a target plus one noise word beat an exact target.
    final targetLen = normalisedTarget.length;
    final minSliceLen = max(1, (targetLen * 0.7).floor());
    final maxSliceLen = (targetLen * config.windowSlack).ceil();
    final maxRetainedWindowLen = maxSliceLen + 3;

    while (window.isNotEmpty) {
      _MatchCandidate? best;

      for (
        int sliceLen = min(maxSliceLen, window.length);
        sliceLen >= minSliceLen;
        sliceLen--
      ) {
        for (
          int startIdx = 0;
          startIdx <= window.length - sliceLen;
          startIdx++
        ) {
          _windowsEvaluated++;
          final candidateTokens = window.sublist(startIdx, startIdx + sliceLen);
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

      final candidateTokens = window.sublist(
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
          window.removeRange(0, best.startIndex + best.length);
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

      window.removeRange(0, best.startIndex + best.length);
    }

    // Retain only enough unmatched context to bridge a phrase split across
    // adjacent final segments. This must happen after scanning the newly
    // arrived segment, otherwise a long phrase repeated twice in one segment
    // can be truncated before either repetition is counted.
    if (window.length > maxRetainedWindowLen) {
      window.removeRange(0, window.length - maxRetainedWindowLen);
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
    _streams.clear();
    openStream(defaultStreamId);
    _observedUtteranceDurationsMs.clear();
    _cachedMedianMs = null;
    _windowsEvaluated = 0;
    _detectionsCount = 0;
    _lastMatchEndMs = null;
  }
}
