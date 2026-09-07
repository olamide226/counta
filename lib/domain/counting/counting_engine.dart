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

  const CountEvent({
    required this.seq,
    required this.source,
    this.confidence = 1.0,
    this.audioOffset = Duration.zero,
    required this.wallClock,
  });

  @override
  String toString() {
    return 'CountEvent(seq: $seq, source: $source, confidence: $confidence, audioOffset: $audioOffset, wallClock: $wallClock)';
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

/// Summary presented at the end of a counting session.
class SessionSummary {
  final int voiceCount;
  final int manualCount;
  final int totalCount;
  final Duration duration;

  const SessionSummary({
    required this.voiceCount,
    required this.manualCount,
    required this.totalCount,
    required this.duration,
  });

  @override
  String toString() {
    return 'SessionSummary(voice: $voiceCount, manual: $manualCount, total: $totalCount, duration: $duration)';
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

  Future<void> start([PhraseSpec? phrase]);
  Future<SessionSummary> stop();
  Future<void> dispose();

  /// Records a count the user entered by hand, alongside any the engine
  /// detects itself. Every engine tracks these, so the session total stays
  /// correct no matter which engine is active.
  void incrementManual();

  /// Removes the most recent manual count, flooring at zero.
  void decrementManual();
}
