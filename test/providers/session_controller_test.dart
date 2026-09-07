import 'package:flutter_test/flutter_test.dart';

import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/state/providers/session_controller.dart';

import '../helpers/fake_counting_engine.dart';

void main() {
  const phrase = PhraseSpec(
    raw: 'I am full of power',
    normalisedTokens: ['i', 'am', 'full', 'of', 'power'],
  );

  group('SessionController microphone permission', () {
    test(
      'denied permission is exposed as a typed status, not an exception',
      () async {
        final engine = FakeCountingEngine(
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
      final engine = FakeCountingEngine(
        startStatus: EngineStatus.permissionDenied,
      );
      final controller = SessionController(engine: engine);

      await controller.startSession(phrase);
      controller.incrementManual();

      expect(controller.total, 1);
      expect(controller.manualCount, 1);

      controller.dispose();
    });

    test('a granted start is voice-active and not permission-denied', () async {
      final engine = FakeCountingEngine(startStatus: EngineStatus.live);
      final controller = SessionController(engine: engine);

      await controller.startSession(phrase);

      expect(controller.isPermissionDenied, isFalse);
      expect(controller.isVoiceActive, isTrue);

      controller.dispose();
    });
  });
}
