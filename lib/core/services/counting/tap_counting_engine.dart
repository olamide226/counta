import 'dart:async';

import '../../../domain/counting/counting_engine.dart';

/// An implementation of [CountingEngine] for manual tap counting.
class TapCountingEngine implements CountingEngine {
  final StreamController<CountEvent> _countsController =
      StreamController<CountEvent>.broadcast();
  final StreamController<EngineStatus> _statusController =
      StreamController<EngineStatus>.broadcast();

  EngineStatus _status = EngineStatus.idle;
  int _seq = 0;
  int _manualCount = 0;
  DateTime? _startTime;

  @override
  Stream<CountEvent> get counts => _countsController.stream;

  @override
  Stream<EngineStatus> get status => _statusController.stream;

  EngineStatus get currentStatus => _status;
  int get manualCount => _manualCount;
  int get totalCount => _manualCount;

  @override
  // Tap counting cannot degrade — there is nothing to explain.
  Stream<String> get diagnostics => const Stream<String>.empty();

  void _setStatus(EngineStatus newStatus) {
    _status = newStatus;
    if (!_statusController.isClosed) {
      _statusController.add(_status);
    }
  }

  @override
  Future<void> start([PhraseSpec? phrase]) async {
    _seq = 0;
    _manualCount = 0;
    _startTime = DateTime.now();
    _setStatus(EngineStatus.live);
  }

  /// Record a manual tap increment.
  @override
  void incrementManual() {
    if (_status != EngineStatus.live && _status != EngineStatus.idle) return;

    _manualCount++;
    _seq++;

    final event = CountEvent(
      seq: _seq,
      source: CountSource.manual,
      confidence: 1.0,
      audioOffset: Duration.zero,
      wallClock: DateTime.now(),
    );

    if (!_countsController.isClosed) {
      _countsController.add(event);
    }
  }

  /// Record a manual decrement, down to a floor of zero for total/manual count.
  @override
  void decrementManual() {
    if (_manualCount > 0) {
      _manualCount--;
    }
  }

  @override
  Future<SessionSummary> stop() async {
    final now = DateTime.now();
    final start = _startTime ?? now;
    final totalDuration = now.difference(start);

    final summary = SessionSummary(
      voiceCount: 0,
      manualCount: _manualCount,
      totalCount: totalCount,
      duration: totalDuration.isNegative ? Duration.zero : totalDuration,
    );

    _setStatus(EngineStatus.idle);
    return summary;
  }

  @override
  Future<void> dispose() async {
    await _countsController.close();
    await _statusController.close();
  }
}
