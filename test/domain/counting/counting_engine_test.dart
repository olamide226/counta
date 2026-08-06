import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/core/services/counting/tap_counting_engine.dart';
import 'package:counta/state/providers/session_controller.dart';

void main() {
  group('TapCountingEngine', () {
    late TapCountingEngine engine;

    setUp(() {
      engine = TapCountingEngine();
    });

    tearDown(() async {
      await engine.dispose();
    });

    test('initial state is idle and count is zero', () {
      expect(engine.currentStatus, EngineStatus.idle);
      expect(engine.manualCount, 0);
      expect(engine.totalCount, 0);
      expect(engine.totalCount, 0);
    });

    test('start transitions status to live', () async {
      await engine.start();
      expect(engine.currentStatus, EngineStatus.live);
    });

    test('incrementManual emits CountEvent and updates manualCount', () async {
      await engine.start();

      final events = <CountEvent>[];
      final subscription = engine.counts.listen(events.add);

      engine.incrementManual();
      engine.incrementManual();

      await pumpEventQueue();

      expect(engine.manualCount, 2);
      expect(events.length, 2);
      expect(events[0].seq, 1);
      expect(events[0].source, CountSource.manual);
      expect(events[1].seq, 2);

      await subscription.cancel();
    });

    test('decrementManual does not go below zero', () async {
      await engine.start();

      engine.incrementManual();
      expect(engine.manualCount, 1);

      engine.decrementManual();
      expect(engine.manualCount, 0);

      // Decrementing again should stay at zero
      engine.decrementManual();
      expect(engine.manualCount, 0);
    });

    test('stop returns SessionSummary and resets status to idle', () async {
      await engine.start();
      engine.incrementManual();
      engine.incrementManual();

      final summary = await engine.stop();

      expect(summary.manualCount, 2);
      expect(summary.voiceCount, 0);
      expect(summary.totalCount, 2);
      expect(engine.currentStatus, EngineStatus.idle);
    });
  });

  group('SessionController', () {
    late SessionController controller;

    setUp(() {
      controller = SessionController();
    });

    tearDown(() {
      controller.dispose();
    });

    test('initial counts are zero', () {
      expect(controller.total, 0);
      expect(controller.voiceCount, 0);
      expect(controller.manualCount, 0);
      expect(controller.status, EngineStatus.idle);
    });

    test('incrementManual updates manualCount and total', () {
      controller.incrementManual();
      controller.incrementManual();

      expect(controller.manualCount, 2);
      expect(controller.voiceCount, 0);
      expect(controller.total, 2);
    });

    test('decrementManual decrements count with floor of zero', () {
      controller.incrementManual();
      expect(controller.total, 1);

      controller.decrementManual();
      expect(controller.total, 0);

      // Extra decrement keeps total at 0
      controller.decrementManual();
      expect(controller.total, 0);
    });

    test('startSession sets active phrase and resets counts', () async {
      const phrase = PhraseSpec(
        raw: "I'm rich in wisdom",
        normalisedTokens: ['i', 'am', 'rich', 'in', 'wisdom'],
        keyterms: ['rich in wisdom'],
      );

      controller.incrementManual();
      expect(controller.total, 1);

      await controller.startSession(phrase);

      expect(controller.activePhrase, phrase);
      expect(controller.total, 0);
      expect(controller.voiceCount, 0);
      expect(controller.manualCount, 0);
      expect(controller.status, EngineStatus.live);
    });

    test('stop returns complete SessionSummary', () async {
      await controller.startSession();
      controller.incrementManual();
      controller.incrementManual();

      final summary = await controller.stop();

      expect(summary.totalCount, 2);
      expect(summary.manualCount, 2);
      expect(summary.voiceCount, 0);
    });

    test('manual taps reach whichever engine is active', () async {
      final engine = _RecordingEngine();
      controller.setEngine(engine);
      await controller.startSession();

      controller.incrementManual();
      controller.incrementManual();
      controller.decrementManual();

      // Regression: an `is TapCountingEngine` guard used to swallow these for
      // any other engine, so a voice session's summary under-reported every
      // tap the user made during it.
      expect(engine.increments, 2);
      expect(engine.decrements, 1);
    });

    test('seed restores a loaded session total', () {
      controller.seed(42);

      expect(controller.total, 42);

      // Regression: loading a saved session left the controller at zero while
      // the UI showed the loaded count, so the next tap collapsed it to 1.
      controller.incrementManual();
      expect(controller.total, 43);
    });

    test('seed floors negative counts at zero', () {
      controller.seed(-5);
      expect(controller.total, 0);
    });
  });
}

/// Counts the manual calls it receives, to prove they are not swallowed.
class _RecordingEngine implements CountingEngine {
  final _counts = StreamController<CountEvent>.broadcast();
  final _status = StreamController<EngineStatus>.broadcast();
  int increments = 0;
  int decrements = 0;

  @override
  Stream<CountEvent> get counts => _counts.stream;
  @override
  Stream<EngineStatus> get status => _status.stream;
  @override
  Stream<String> get diagnostics => const Stream<String>.empty();

  @override
  Future<void> start([PhraseSpec? phrase]) async =>
      _status.add(EngineStatus.live);

  @override
  void incrementManual() => increments++;

  @override
  void decrementManual() => decrements++;

  @override
  Future<SessionSummary> stop() async => const SessionSummary(
        voiceCount: 0,
        manualCount: 0,
        totalCount: 0,
        duration: Duration.zero,
      );

  @override
  Future<void> dispose() async {
    await _counts.close();
    await _status.close();
  }
}
