import 'dart:async';

import 'package:counta/domain/counting/counting_engine.dart';

/// Configurable [CountingEngine] double.
///
/// Covers what tests actually need from an engine: what it was started with,
/// how many manual calls reached it, whether it was disposed, and what status
/// it reports back. [startStatus] drives the terminal-status paths (permission
/// denied, error, exhausted) that would otherwise need a real microphone.
///
/// Statuses are added synchronously inside [start], exactly as the real engines
/// do, so the microtask ordering callers depend on is the ordering under test.
class FakeCountingEngine implements CountingEngine {
  FakeCountingEngine({this.startStatus = EngineStatus.live});

  final EngineStatus startStatus;

  final _counts = StreamController<CountEvent>.broadcast();
  final _status = StreamController<EngineStatus>.broadcast();
  final _diagnostics = StreamController<String>.broadcast();

  int startCount = 0;
  int stopCount = 0;
  int increments = 0;
  int decrements = 0;
  bool disposed = false;
  PhraseSpec? lastPhrase;

  @override
  Stream<CountEvent> get counts => _counts.stream;

  @override
  Stream<EngineStatus> get status => _status.stream;

  @override
  Stream<String> get diagnostics => _diagnostics.stream;

  @override
  Future<void> start([PhraseSpec? phrase]) async {
    startCount++;
    lastPhrase = phrase;
    if (startStatus == EngineStatus.permissionDenied) {
      emitDiagnostic('Microphone access is needed for voice counting.');
    }
    emitStatus(startStatus);
  }

  @override
  Future<SessionSummary> stop() async {
    stopCount++;
    emitStatus(EngineStatus.idle);
    final manual = (increments - decrements).clamp(0, 1 << 30);
    return SessionSummary(
      voiceCount: 0,
      manualCount: manual,
      totalCount: manual,
      duration: Duration.zero,
    );
  }

  @override
  void incrementManual() => increments++;

  @override
  void decrementManual() => decrements++;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _counts.close();
    await _status.close();
    await _diagnostics.close();
  }

  /// Pushes a status the way a real engine would mid-session.
  void emitStatus(EngineStatus value) {
    if (!_status.isClosed) _status.add(value);
  }

  /// Pushes a voice detection the way a real engine would mid-session.
  void emitVoiceCount({int seq = 1}) {
    if (_counts.isClosed) return;
    _counts.add(
      CountEvent(
        seq: seq,
        source: CountSource.voice,
        wallClock: DateTime(2026, 3, 1),
      ),
    );
  }

  void emitDiagnostic(String message) {
    if (!_diagnostics.isClosed) _diagnostics.add(message);
  }
}
