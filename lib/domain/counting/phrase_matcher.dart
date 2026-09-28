import 'dart:math';

import 'counting_engine.dart';
import 'phrase_normaliser.dart';
import 'transcript_segment.dart';

class Detection {
  final double score;
  final Duration audioOffset;
  final String matchedText;
  final DateTime detectedAt;

  /// Which of the session's phrases this detection was accepted against.
  ///
  /// A session counts one total whatever the phrase, so nothing downstream
  /// has to branch on this — it exists so the summary can show the split.
  final PhraseSpec phrase;

  Detection({
    required this.score,
    required this.audioOffset,
    required this.matchedText,
    required this.phrase,
    DateTime? detectedAt,
  }) : detectedAt = detectedAt ?? DateTime.now();

  @override
  String toString() =>
      'Detection(score: ${score.toStringAsFixed(2)}, offset: $audioOffset, text: "$matchedText", phrase: "${phrase.raw}")';
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
  final _Target target;

  const _MatchCandidate({
    required this.startIndex,
    required this.length,
    required this.score,
    required this.target,
  });
}

/// One phrase the matcher is listening for, with everything derived from it
/// that would otherwise be recomputed on every candidate slice.
///
/// Holding the derived bounds per phrase is what keeps a set of mixed lengths
/// honest: a three-token phrase must not be compared against a fifteen-token
/// slice just because some other phrase in the set is long enough to want one.
class _Target {
  _Target({
    required this.spec,
    required this.tokens,
    required double windowSlack,
  }) : minSliceLength = max(1, (tokens.length * 0.7).floor()),
       maxSliceLength = (tokens.length * windowSlack).ceil(),
       _headAnchorLength = max(2, tokens.length ~/ 3);

  final PhraseSpec spec;
  final List<String> tokens;
  final int minSliceLength;
  final int maxSliceLength;
  final int _headAnchorLength;

  int get length => tokens.length;

  /// How many leading target tokens a candidate must reproduce exactly to
  /// count as anchored. Anchoring needs at least four target tokens so that
  /// the head and tail leave a middle for the relaxation to apply to.
  static const int _minAnchoredTargetLength = 4;

  bool isAnchored(List<String> candidate) {
    if (tokens.length < _minAnchoredTargetLength) return false;
    if (candidate.length <= _headAnchorLength) return false;
    for (int i = 0; i < _headAnchorLength; i++) {
      if (candidate[i] != tokens[i]) return false;
    }
    return candidate.last == tokens.last;
  }
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
  /// Every phrase this session counts. All of them share one token window and
  /// one refractory period, so a single utterance can satisfy at most one of
  /// them — which is what stops two near-identical phrases counting the same
  /// breath twice.
  final PhraseSet target;

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

  /// Convenience for the single-phrase case, which is most sessions and every
  /// fixture replay.
  PhraseMatcher.single(
    PhraseSpec phrase, {
    MatcherConfig config = const MatcherConfig(),
  }) : this(target: PhraseSet.single(phrase), config: config);

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

  /// The phrases that can actually match. One that normalises to nothing is
  /// dropped here rather than skipped on every candidate slice, which also
  /// keeps the scan bounds below from being widened by a phrase that will
  /// never claim anything.
  late final List<_Target> _targets = [
    for (final spec in target.phrases)
      if (_normaliseSpec(spec) case final tokens when tokens.isNotEmpty)
        _Target(spec: spec, tokens: tokens, windowSlack: config.windowSlack),
  ];

  List<String> _normaliseSpec(PhraseSpec spec) => List.unmodifiable(
    spec.normalisedTokens.isNotEmpty
        ? spec.normalisedTokens
        : normaliseText(spec.raw),
  );

  /// Slice lengths worth cutting at all: the union of what any one phrase
  /// would consider. Each phrase still rejects the lengths outside its own
  /// bounds, so the union only decides how wide the window scan goes.
  late final int _scanMinSliceLength = _targets
      .map((t) => t.minSliceLength)
      .reduce(min);
  late final int _scanMaxSliceLength = _targets
      .map((t) => t.maxSliceLength)
      .reduce(max);

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
    final targets = _targets;
    if (targets.isEmpty) return [];

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
    //
    // Every phrase in the set is scored against the same slice, and the best
    // (slice, phrase) pair wins outright. One shared scan is what makes the
    // acceptance decision single: two phrases cannot each claim the same
    // tokens, because the winner retires them for all of them.
    final maxRetainedWindowLen = _scanMaxSliceLength + 3;

    while (window.isNotEmpty) {
      _MatchCandidate? best;

      for (
        int sliceLen = min(_scanMaxSliceLength, window.length);
        sliceLen >= _scanMinSliceLength;
        sliceLen--
      ) {
        for (
          int startIdx = 0;
          startIdx <= window.length - sliceLen;
          startIdx++
        ) {
          List<String>? candidateStringList;

          for (final target in targets) {
            // A slice outside this phrase's own bounds is not a near miss,
            // it is a different length of thing entirely.
            if (sliceLen < target.minSliceLength ||
                sliceLen > target.maxSliceLength) {
              continue;
            }

            // Built once per slice, and only for a slice some phrase wants.
            candidateStringList ??= [
              for (int i = startIdx; i < startIdx + sliceLen; i++)
                window[i].token,
            ];

            _windowsEvaluated++;
            final similarity = calculateTokenSimilarity(
              candidateStringList,
              target.tokens,
            );

            final threshold = target.isAnchored(candidateStringList)
                ? min(config.threshold, config.anchoredThreshold)
                : config.threshold;
            if (similarity < threshold) continue;

            final candidate = _MatchCandidate(
              startIndex: startIdx,
              length: sliceLen,
              score: similarity,
              target: target,
            );
            if (_isBetterCandidate(candidate, best)) {
              best = candidate;
            }
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
      if (best.length == best.target.length) {
        _observeUtterance(utteranceDurationMs);
      }

      final matchedText = candidateTokens.map((t) => t.token).join(' ');
      final audioOffset = Duration(milliseconds: candidateStartMs.round());

      detections.add(
        Detection(
          score: best.score,
          audioOffset: audioOffset,
          matchedText: matchedText,
          phrase: best.target.spec,
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

  bool _isBetterCandidate(_MatchCandidate candidate, _MatchCandidate? current) {
    if (current == null) return true;
    if (candidate.score != current.score) {
      return candidate.score > current.score;
    }

    // Each candidate is measured against the length of the phrase it matched,
    // not against a single session-wide target length.
    final candidateLengthDifference =
        (candidate.length - candidate.target.length).abs();
    final currentLengthDifference = (current.length - current.target.length)
        .abs();
    if (candidateLengthDifference != currentLengthDifference) {
      return candidateLengthDifference < currentLengthDifference;
    }

    // Earliest wins, and nothing is allowed to outrank position.
    //
    // Accepting a candidate retires every token before it too, so preferring
    // a later candidate does not merely reorder the output — it destroys the
    // earlier match without ever emitting it. A set containing both "peace be
    // still" and a longer phrase lost the first of them whenever the user
    // said it first, and counted both when they said it in the other order.
    //
    // Preferring the longer phrase needs no rule of its own: where one phrase
    // is contained in another, the longer match starts at or before the
    // shorter one, so position already picks it. Where they start at the same
    // token the slice loop runs longest-first, so the longer is seen first and
    // kept.
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
