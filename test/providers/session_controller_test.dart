import 'package:flutter_test/flutter_test.dart';

import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/state/providers/session_controller.dart';

import '../helpers/fake_counting_engine.dart';

void main() {
  const phrase = PhraseSpec(
    raw: 'I am full of power',
    normalisedTokens: ['i', 'am', 'full', 'of', 'power'],
  );

  /// Builds a controller wired the way the provider wires the real one.
  ({
    SessionController controller,
    FakeCountingEngine voice,
    List<FakeCountingEngine> taps,
  })
  build({
    EngineStatus voiceStatus = EngineStatus.live,
    Future<bool> Function()? disclosureGate,
  }) {
    final voice = FakeCountingEngine(startStatus: voiceStatus);
    final taps = <FakeCountingEngine>[];
    final controller = SessionController(
      engine: FakeCountingEngine(),
      voiceEngineFactory: () => voice,
      tapEngineFactory: () {
        final engine = FakeCountingEngine();
        taps.add(engine);
        return engine;
      },
      disclosureGate: disclosureGate,
    );
    return (controller: controller, voice: voice, taps: taps);
  }

  group('startVoiceSession', () {
    test('a granted start installs the voice engine and runs', () async {
      final t = build();

      final outcome = await t.controller.startVoiceSession(phrase);

      expect(outcome, EngineStatus.live);
      expect(t.voice.startCount, 1);
      expect(t.voice.lastPhrase, phrase);
      expect(t.controller.isVoiceActive, isTrue);
      expect(t.controller.activePhrase, phrase);

      t.controller.dispose();
    });

    test('denied permission falls back to the tap engine', () async {
      final t = build(voiceStatus: EngineStatus.permissionDenied);

      final outcome = await t.controller.startVoiceSession(phrase);

      // The screen learns what happened from the return value, because by now
      // the failed session has already been rolled back.
      expect(outcome, EngineStatus.permissionDenied);
      expect(t.controller.status, EngineStatus.idle);
      expect(t.controller.isVoiceActive, isFalse);
      expect(t.taps, hasLength(1));
      expect(t.voice.disposed, isTrue);

      t.controller.dispose();
    });

    test('a denied start rolls the phrase back', () async {
      final t = build(voiceStatus: EngineStatus.permissionDenied);

      await t.controller.startVoiceSession(phrase);

      // Regression: the phrase stayed set after a denied start, so the
      // tap-only session that followed was saved as a voice session
      // (session_controller.dart:119).
      expect(t.controller.activePhrase, isNull);

      t.controller.incrementManual();
      expect(t.controller.total, 1);
      expect(t.controller.manualCount, 1);
      expect(t.controller.activePhrase, isNull);

      t.controller.dispose();
    });

    test('an errored or exhausted start falls back too', () async {
      for (final status in [EngineStatus.error, EngineStatus.exhausted]) {
        final t = build(voiceStatus: status);

        final outcome = await t.controller.startVoiceSession(phrase);

        // Only permissionDenied used to be handled, so an errored start left
        // a dead cloud engine installed and the phrase marked active.
        expect(outcome, status, reason: '$status');
        expect(t.controller.status, EngineStatus.idle, reason: '$status');
        expect(t.controller.activePhrase, isNull, reason: '$status');
        expect(t.voice.disposed, isTrue, reason: '$status');

        t.controller.dispose();
      }
    });

    test('declining the disclosure never installs the voice engine', () async {
      final t = build(disclosureGate: () async => false);

      final outcome = await t.controller.startVoiceSession(phrase);

      expect(outcome, EngineStatus.idle);
      expect(t.voice.startCount, 0);
      expect(t.controller.activePhrase, isNull);
      expect(t.controller.isVoiceActive, isFalse);

      t.controller.dispose();
    });

    test('accepting the disclosure lets the session through', () async {
      var asked = 0;
      final t = build(
        disclosureGate: () async {
          asked++;
          return true;
        },
      );

      final outcome = await t.controller.startVoiceSession(phrase);

      expect(asked, 1);
      expect(outcome, EngineStatus.live);
      expect(t.voice.startCount, 1);

      t.controller.dispose();
    });
  });

  group('stopVoiceSession', () {
    test('stops the engine and hands back to tap counting', () async {
      final t = build();
      await t.controller.startVoiceSession(phrase);

      await t.controller.stopVoiceSession();

      expect(t.voice.stopCount, 1);
      expect(t.voice.disposed, isTrue);
      expect(t.taps, hasLength(1));
      expect(t.controller.isVoiceActive, isFalse);

      t.controller.dispose();
    });
  });

  group('setEngine', () {
    test('disposes the engine it replaces', () async {
      final first = FakeCountingEngine();
      final second = FakeCountingEngine();
      final controller = SessionController(engine: first);

      controller.setEngine(second);

      // Each swap used to leak a microphone, a socket and three stream
      // controllers for the life of the app.
      expect(first.disposed, isTrue);
      expect(second.disposed, isFalse);

      controller.dispose();
    });

    test('a manual count still works after a denied voice start', () async {
      final t = build(voiceStatus: EngineStatus.permissionDenied);

      await t.controller.startVoiceSession(phrase);
      t.controller.incrementManual();

      expect(t.controller.total, 1);
      expect(t.controller.manualCount, 1);
      expect(t.taps.single.increments, 1);

      t.controller.dispose();
    });
  });
}
