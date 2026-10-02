import 'package:flutter_test/flutter_test.dart';

import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/state/providers/session_controller.dart';

import 'package:counta/core/services/live_activity_service.dart';
import 'package:counta/domain/counting/block_service.dart';

import '../helpers/fake_counting_engine.dart';
import '../helpers/session_factory.dart';

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

      final outcome = await t.controller.startVoiceSession(
        PhraseSet.single(phrase),
      );

      expect(outcome, EngineStatus.live);
      expect(t.voice.startCount, 1);
      expect(t.voice.lastPhrases, PhraseSet.single(phrase));
      expect(t.controller.isVoiceActive, isTrue);
      expect(t.controller.activePhrases, PhraseSet.single(phrase));

      t.controller.dispose();
    });

    test('denied permission falls back to the tap engine', () async {
      final t = build(voiceStatus: EngineStatus.permissionDenied);

      final outcome = await t.controller.startVoiceSession(
        PhraseSet.single(phrase),
      );

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

      await t.controller.startVoiceSession(PhraseSet.single(phrase));

      // Regression: the phrase stayed set after a denied start, so the
      // tap-only session that followed was saved as a voice session
      // (session_controller.dart:119).
      expect(t.controller.activePhrases, isNull);

      t.controller.incrementManual();
      expect(t.controller.total, 1);
      expect(t.controller.manualCount, 1);
      expect(t.controller.activePhrases, isNull);

      t.controller.dispose();
    });

    test('an errored or exhausted start falls back too', () async {
      for (final status in [EngineStatus.error, EngineStatus.exhausted]) {
        final t = build(voiceStatus: status);

        final outcome = await t.controller.startVoiceSession(
          PhraseSet.single(phrase),
        );

        // Only permissionDenied used to be handled, so an errored start left
        // a dead cloud engine installed and the phrase marked active.
        expect(outcome, status, reason: '$status');
        expect(t.controller.status, EngineStatus.idle, reason: '$status');
        expect(t.controller.activePhrases, isNull, reason: '$status');
        expect(t.voice.disposed, isTrue, reason: '$status');

        t.controller.dispose();
      }
    });

    test('declining the disclosure never installs the voice engine', () async {
      final t = build(disclosureGate: () async => false);

      final outcome = await t.controller.startVoiceSession(
        PhraseSet.single(phrase),
      );

      expect(outcome, EngineStatus.idle);
      expect(t.voice.startCount, 0);
      expect(t.controller.activePhrases, isNull);
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

      final outcome = await t.controller.startVoiceSession(
        PhraseSet.single(phrase),
      );

      expect(asked, 1);
      expect(outcome, EngineStatus.live);
      expect(t.voice.startCount, 1);

      t.controller.dispose();
    });
  });

  group('a start that throws', () {
    test('rolls back to tap counting and tells the caller why', () async {
      final voice = FakeCountingEngine(
        startStatus: EngineStatus.exhausted,
        startError: const BlockInsufficientCredit(balance: 0, required: 5),
      );
      final taps = <FakeCountingEngine>[];
      final controller = SessionController(
        engine: FakeCountingEngine(),
        voiceEngineFactory: () => voice,
        tapEngineFactory: () {
          final engine = FakeCountingEngine();
          taps.add(engine);
          return engine;
        },
      );

      // Regression: the throw skipped the roll-back, leaving a dead voice
      // engine installed with the phrase still marked active.
      await expectLater(
        controller.startVoiceSession(PhraseSet.single(phrase)),
        throwsA(isA<BlockInsufficientCredit>()),
      );

      expect(controller.activePhrases, isNull);
      expect(controller.isVoiceActive, isFalse);
      expect(voice.disposed, isTrue);
      expect(taps, hasLength(1));
      // Refused at the door is explained on the setup screen, where the user
      // is. The mid-session notice is for a session that was running.
      expect(controller.outOfMinutes, isFalse);

      controller.dispose();
    });
  });

  group('running out of minutes', () {
    test('a running session that runs out says so', () async {
      final t = build();
      await t.controller.startVoiceSession(PhraseSet.single(phrase));
      await pumpEventQueue();

      t.voice.emitStatus(EngineStatus.exhausted);
      await pumpEventQueue();

      expect(t.controller.outOfMinutes, isTrue);
      expect(t.controller.isVoiceActive, isFalse);
      // The phrase stays: this is still the same session, and picking it
      // back up must not mean typing it again.
      expect(t.controller.activePhrases, PhraseSet.single(phrase));

      t.controller.dispose();
    });

    test('the notice goes when dismissed, resumed or reset', () async {
      Future<SessionController> ranOut() async {
        final t = build();
        await t.controller.startVoiceSession(PhraseSet.single(phrase));
        await pumpEventQueue();
        t.voice.emitStatus(EngineStatus.exhausted);
        await pumpEventQueue();
        expect(t.controller.outOfMinutes, isTrue);
        return t.controller;
      }

      final dismissed = await ranOut();
      dismissed.dismissOutOfMinutes();
      expect(dismissed.outOfMinutes, isFalse);
      dismissed.dispose();

      final reset = await ranOut();
      reset.reset();
      expect(reset.outOfMinutes, isFalse);
      reset.dispose();
    });

    test('a session that ends by itself ends its Live Activity', () async {
      final activity = _RecordingLiveActivity();
      final voice = FakeCountingEngine();
      final controller = SessionController(
        engine: FakeCountingEngine(),
        liveActivityService: activity,
        voiceEngineFactory: () => voice,
        tapEngineFactory: FakeCountingEngine.new,
      );
      await controller.startVoiceSession(PhraseSet.single(phrase));
      await pumpEventQueue();
      expect(activity.started, 1);

      // Regression: only `stop()` ended it, and nothing calls `stop()` when
      // the engine gives up, so the lock screen showed a session that was
      // over.
      voice.emitStatus(EngineStatus.exhausted);
      await pumpEventQueue();

      expect(activity.ended, 1);

      controller.dispose();
    });
  });

  group('voice minutes used', () {
    test('counts what was charged since the count began', () {
      final t = build();
      // Earlier sessions since launch had already cost 7.
      t.controller.reportVoiceMinutes(7);
      t.controller.reset();

      t.controller.reportVoiceMinutes(12);
      expect(t.controller.voiceMinutesUsed, 5);

      // Unused minutes coming back lower it again.
      t.controller.reportVoiceMinutes(8);
      expect(t.controller.voiceMinutesUsed, 1);

      t.controller.dispose();
    });

    test('a new count starts from nothing', () {
      final t = build();
      t.controller.reportVoiceMinutes(5);
      expect(t.controller.voiceMinutesUsed, 5);

      t.controller.reset();

      expect(t.controller.voiceMinutesUsed, 0);
      t.controller.dispose();
    });

    test('a restored session keeps what it had already cost', () {
      final t = build();
      t.controller.reportVoiceMinutes(3);

      t.controller.restore(
        testSession(finalCount: 40).copyWith(creditsConsumed: 6),
      );
      expect(t.controller.voiceMinutesUsed, 6);

      t.controller.reportVoiceMinutes(5);
      expect(t.controller.voiceMinutesUsed, 8);

      t.controller.dispose();
    });
  });

  group('stopVoiceSession', () {
    test('stops the engine and hands back to tap counting', () async {
      final t = build();
      await t.controller.startVoiceSession(PhraseSet.single(phrase));

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

      await t.controller.startVoiceSession(PhraseSet.single(phrase));
      t.controller.incrementManual();

      expect(t.controller.total, 1);
      expect(t.controller.manualCount, 1);
      expect(t.taps.single.increments, 1);

      t.controller.dispose();
    });
  });

  group('status sets', () {
    test('no status is both running and terminal', () {
      expect(
        SessionController.runningStatuses.intersection(
          SessionController.terminalStatuses,
        ),
        isEmpty,
      );
    });

    test('a session that cannot be configured is not a running one', () {
      // The guard deciding whether a setup is worth remembering used to read
      // "not terminal and not idle", which counted `notConfigured` — a build
      // that can never obtain a credential — as a successful start.
      expect(
        SessionController.runningStatuses.contains(EngineStatus.notConfigured),
        isFalse,
      );
    });

    test('every status is classified, or listed here as deliberately not', () {
      // `notConfigured` is in neither set today: it is not a running session,
      // but it is not treated as terminal either, so `startVoiceSession`
      // leaves the engine installed and the banner explains itself instead.
      // That is worth revisiting rather than an oversight — and pinning it
      // means a status added later has to be classified, instead of silently
      // inheriting whichever branch it falls through to.
      const unclassified = {EngineStatus.idle, EngineStatus.notConfigured};

      expect({
        ...SessionController.runningStatuses,
        ...SessionController.terminalStatuses,
        ...unclassified,
      }, EngineStatus.values.toSet());
    });
  });

  group('the per-phrase split', () {
    /// Counts reach the controller through a broadcast stream, so the
    /// listener runs on a later microtask than the emit.
    Future<void> settle() => Future<void>.delayed(Duration.zero);

    final phrases = PhraseSet([
      const PhraseSpec(
        raw: 'I am full of power',
        normalisedTokens: ['i', 'am', 'full', 'of', 'power'],
      ),
      const PhraseSpec(
        raw: 'I walk in favour',
        normalisedTokens: ['i', 'walk', 'in', 'favour'],
      ),
    ]);

    test('counts land on the phrase that matched', () async {
      final t = build();
      await t.controller.startVoiceSession(phrases);

      t.voice.emitVoiceCount(phrase: 'I am full of power');
      t.voice.emitVoiceCount(phrase: 'I walk in favour');
      t.voice.emitVoiceCount(phrase: 'I am full of power');
      await settle();

      expect(t.controller.voiceCount, 3);
      expect(t.controller.voiceCountsByPhrase, {
        'I am full of power': 2,
        'I walk in favour': 1,
      });
      expect(t.controller.lastVoicePhrase, 'I am full of power');
    });

    test('a count with no phrase named falls to the primary', () async {
      // The tap engine and older events carry no phrase; the split must still
      // add up rather than silently lose counts.
      final t = build();
      await t.controller.startVoiceSession(phrases);

      t.voice.emitVoiceCount();

      await settle();

      expect(t.controller.voiceCountsByPhrase, {'I am full of power': 1});
    });

    test(
      'undoing a voice count takes it off the phrase that earned it',
      () async {
        final t = build();
        await t.controller.startVoiceSession(phrases);
        t.voice.emitVoiceCount(phrase: 'I am full of power');
        t.voice.emitVoiceCount(phrase: 'I walk in favour');
        await settle();

        t.controller.decrementManual();

        expect(t.controller.voiceCount, 1);
        expect(
          t.controller.voiceCountsByPhrase,
          {'I am full of power': 1},
          reason: 'the split must keep summing to the voice count',
        );
      },
    );

    test('the split survives more undos than there were counts', () async {
      final t = build();
      await t.controller.startVoiceSession(phrases);
      t.voice.emitVoiceCount(phrase: 'I walk in favour');
      await settle();

      t.controller.decrementManual();
      t.controller.decrementManual();

      expect(t.controller.voiceCount, 0);
      expect(t.controller.voiceCountsByPhrase, isEmpty);
    });

    test('the summary carries the split', () async {
      final t = build();
      await t.controller.startVoiceSession(phrases);
      t.voice.emitVoiceCount(phrase: 'I walk in favour');
      await settle();

      final summary = await t.controller.stop();

      expect(summary.voiceCountsByPhrase, {'I walk in favour': 1});
    });

    test('resetting clears the split with the counts', () async {
      final t = build();
      await t.controller.startVoiceSession(phrases);
      t.voice.emitVoiceCount(phrase: 'I walk in favour');
      await settle();

      t.controller.reset();

      expect(t.controller.voiceCountsByPhrase, isEmpty);
      expect(t.controller.lastVoicePhrase, isNull);
    });
  });
}

/// Counts starts and ends without touching ActivityKit.
class _RecordingLiveActivity extends LiveActivityService {
  int started = 0;
  int ended = 0;

  @override
  Future<void> startActivity({
    required String phrase,
    required int count,
    required int voiceCount,
    required int manualCount,
    required String status,
  }) async {
    started++;
  }

  @override
  void updateActivity({
    required String phrase,
    required int count,
    required int voiceCount,
    required int manualCount,
    required String status,
    bool force = false,
  }) {}

  @override
  Future<void> endActivity() async {
    ended++;
  }
}
