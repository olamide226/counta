import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/state/providers/session_controller.dart';

/// Engine that answers every start with a fixed status, so the controller's
/// handling of the permission path can be exercised without a microphone.
class ScriptedEngine implements CountingEngine {
  ScriptedEngine({required this.startStatus});

  final EngineStatus startStatus;
  final _counts = StreamController<CountEvent>.broadcast();
  final _status = StreamController<EngineStatus>.broadcast();
  final _diagnostics = StreamController<String>.broadcast();
  int startCount = 0;
  int stopCount = 0;

  @override
  Stream<CountEvent> get counts => _counts.stream;

  @override
  Stream<EngineStatus> get status => _status.stream;

  @override
  Stream<String> get diagnostics => _diagnostics.stream;

  @override
  Future<void> start([PhraseSpec? phrase]) async {
    startCount++;
    if (startStatus == EngineStatus.permissionDenied) {
      _diagnostics.add('Microphone access is needed for voice counting.');
    }
    _status.add(startStatus);
    // Let the broadcast listeners run before start() returns, as the real
    // engine's awaits would.
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<SessionSummary> stop() async {
    stopCount++;
    _status.add(EngineStatus.idle);
    await Future<void>.delayed(Duration.zero);
    return const SessionSummary(
      voiceCount: 0,
      manualCount: 0,
      totalCount: 0,
      duration: Duration.zero,
    );
  }

  @override
  void incrementManual() {}

  @override
  void decrementManual() {}

  @override
  Future<void> dispose() async {
    await _counts.close();
    await _status.close();
    await _diagnostics.close();
  }
}

void main() {
  const phrase = PhraseSpec(
    raw: 'I am full of power',
    normalisedTokens: ['i', 'am', 'full', 'of', 'power'],
  );

  group('SessionController microphone permission', () {
    test(
      'denied permission is exposed as a typed status, not an exception',
      () async {
        final engine = ScriptedEngine(
          startStatus: EngineStatus.permissionDenied,
        );
        final controller = SessionController(engine: engine);
        var notifications = 0;
        controller.addListener(() => notifications++);

        await controller.startSession(phrase);

        expect(controller.isPermissionDenied, isTrue);
        expect(controller.status, EngineStatus.permissionDenied);
        expect(controller.isVoiceActive, isFalse);
        expect(controller.lastDiagnostic, contains('Microphone'));
        expect(notifications, greaterThan(0));
        // The phrase is kept so a retry after granting access resumes it.
        expect(controller.activePhrase, phrase);

        controller.dispose();
      },
    );

    test('a manual count still works after a denied voice start', () async {
      final engine = ScriptedEngine(startStatus: EngineStatus.permissionDenied);
      final controller = SessionController(engine: engine);

      await controller.startSession(phrase);
      controller.incrementManual();

      expect(controller.total, 1);
      expect(controller.manualCount, 1);

      controller.dispose();
    });

    test('a granted start is voice-active and not permission-denied', () async {
      final engine = ScriptedEngine(startStatus: EngineStatus.live);
      final controller = SessionController(engine: engine);

      await controller.startSession(phrase);

      expect(controller.isPermissionDenied, isFalse);
      expect(controller.isVoiceActive, isTrue);

      controller.dispose();
    });
  });
}
