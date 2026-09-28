import 'dart:async';

/// Status of the counting engine lifecycle.
enum EngineStatus {
  idle,

  /// This build cannot obtain a streaming credential at all, so no session can
  /// start. A configuration state, not a failure of a running session: the
  /// engine reports it instead of throwing an unhandled error, and the UI
  /// explains it rather than leaving the user with a counter that never moved.
  notConfigured,
  requestingBlock,
  connecting,
  live,
  reconnecting,
  degraded,
  exhausted,
  error,

  /// The user refused microphone access, so no audio can be captured and no
  /// socket was opened. Distinct from [error] because the fix is in system
  /// settings, not a retry.
  permissionDenied,
}

/// Thrown when voice counting cannot start because there is no way to obtain a
/// streaming credential — no block token from the voice-block service, and no
/// developer key in a dev build.
///
/// Distinct from a transport failure: retrying will not help and the message is
/// meant to be shown to the user, so [CloudCountingEngine] maps it to
/// [EngineStatus.notConfigured] rather than [EngineStatus.error].
class VoiceUnavailable implements Exception {
  const VoiceUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Source of a count event (voice detection or manual tap).
enum CountSource { voice, manual }

/// Event emitted whenever a count increment occurs.
class CountEvent {
  final int seq;
  final CountSource source;
  final double confidence;
  final Duration audioOffset;
  final DateTime wallClock;

  /// Raw text of the phrase this detection matched, when the session is
  /// counting more than one and the split is worth reporting back.
  ///
  /// Null for manual taps, which belong to no phrase in particular, and for
  /// engines that do not match phrases at all.
  final String? phrase;

  const CountEvent({
    required this.seq,
    required this.source,
    this.confidence = 1.0,
    this.audioOffset = Duration.zero,
    required this.wallClock,
    this.phrase,
  });

  @override
  String toString() {
    return 'CountEvent(seq: $seq, source: $source, confidence: $confidence, audioOffset: $audioOffset, wallClock: $wallClock, phrase: $phrase)';
  }
}

/// Target phrase specification for voice counting sessions.
class PhraseSpec {
  final String raw;
  final List<String> normalisedTokens;
  final List<String> keyterms;
  final String languageCode;

  const PhraseSpec({
    required this.raw,
    required this.normalisedTokens,
    this.keyterms = const [],
    this.languageCode = 'en',
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PhraseSpec &&
          runtimeType == other.runtimeType &&
          raw == other.raw &&
          languageCode == other.languageCode;

  @override
  int get hashCode => raw.hashCode ^ languageCode.hashCode;
}

/// How a set of phrases reads where only one line fits: the first phrase, and
/// how many more there are.
///
/// A top-level function rather than a [PhraseSet] member because saved
/// sessions and history entries only hold raw text, and they must read the
/// same as the live session did.
String phraseSetLabel(List<String> rawPhrases) {
  if (rawPhrases.isEmpty) return '';
  if (rawPhrases.length == 1) return rawPhrases.single;
  return '${rawPhrases.first} +${rawPhrases.length - 1} more';
}

/// The phrases one session counts against.
///
/// A session keeps a single running total however many phrases are active —
/// any of them advances it — so this is not a list of counters. It exists
/// because "what is this session counting" is asked by the matcher, the
/// socket, the banner, the notification, the checkpoint and the saved record,
/// and every one of them would otherwise reinvent `phrases.first` and its own
/// way of writing "and two more".
///
/// Always non-empty: a session with nothing to listen for is not a session,
/// and letting the empty case exist pushes a null check into all six callers.
class PhraseSet {
  PhraseSet(List<PhraseSpec> phrases)
    : assert(phrases.isNotEmpty, 'A phrase set needs at least one phrase'),
      phrases = List.unmodifiable(phrases);

  PhraseSet.single(PhraseSpec phrase) : phrases = List.unmodifiable([phrase]);

  final List<PhraseSpec> phrases;

  /// The phrase that stands for the set wherever only one will fit.
  PhraseSpec get primary => phrases.first;

  int get length => phrases.length;
  bool get isMultiple => phrases.length > 1;

  List<String> get rawPhrases => [for (final p in phrases) p.raw];

  /// Every engine here is single-language, so the set speaks for its primary.
  String get languageCode => primary.languageCode;

  /// One-line rendering for a banner, notification or Live Activity.
  String get label => phraseSetLabel(rawPhrases);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! PhraseSet || other.phrases.length != phrases.length) {
      return false;
    }
    for (int i = 0; i < phrases.length; i++) {
      if (phrases[i] != other.phrases[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(phrases);

  @override
  String toString() => 'PhraseSet(${rawPhrases.join(" | ")})';
}

/// Summary presented at the end of a counting session.
class SessionSummary {
  final int voiceCount;
  final int manualCount;
  final int totalCount;
  final Duration duration;

  /// Voice detections split by the phrase that matched, keyed by raw text.
  ///
  /// Empty for a tap-only session. For a single-phrase voice session it holds
  /// the one entry, so the summary screens need no special case for the count
  /// of phrases.
  final Map<String, int> voiceCountsByPhrase;

  const SessionSummary({
    required this.voiceCount,
    required this.manualCount,
    required this.totalCount,
    required this.duration,
    this.voiceCountsByPhrase = const {},
  });

  @override
  String toString() {
    return 'SessionSummary(voice: $voiceCount, manual: $manualCount, total: $totalCount, duration: $duration, byPhrase: $voiceCountsByPhrase)';
  }
}

/// Abstraction seam for counting engines (e.g. tap counting vs cloud streaming engine).
abstract class CountingEngine {
  Stream<CountEvent> get counts;
  Stream<EngineStatus> get status;

  /// Human-readable explanations of why counting degraded, for the UI to show
  /// instead of leaving the user staring at a counter that stopped moving.
  ///
  /// Part of the contract rather than a cloud-engine extra: callers must not
  /// have to type-check the engine to find out whether it can explain itself.
  /// Engines that never degrade return an empty stream.
  Stream<String> get diagnostics;

  Future<void> start([PhraseSet? phrases]);
  Future<SessionSummary> stop();
  Future<void> dispose();

  /// Records a count the user entered by hand, alongside any the engine
  /// detects itself. Every engine tracks these, so the session total stays
  /// correct no matter which engine is active.
  void incrementManual();

  /// Removes the most recent manual count, flooring at zero.
  void decrementManual();
}
