import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/domain/models/count_session.dart';
import 'package:counta/domain/models/enums.dart';
import 'package:counta/state/providers/session_checkpointer.dart';
import 'package:counta/state/providers/session_controller.dart';

import '../helpers/checkpoint_store.dart';
import '../helpers/fake_counting_engine.dart';

CountSession snapshot(SessionController controller, String id) {
  return CountSession(
    id: id,
    mantra: controller.activePhrase?.raw ?? 'Recovered session',
    startedAt: DateTime(2026, 1, 1),
    endedAt: DateTime(2026, 1, 1),
    finalCount: controller.total,
    soundMode: SoundMode.mute,
    themeModeChoice: ThemeModeChoice.system,
    themeId: AppThemeId.ocean,
    phrase: controller.activePhrase?.raw,
    voiceCount: controller.voiceCount,
    manualCount: controller.manualCount,
    completed: false,
  );
}

const phrase = PhraseSpec(raw: 'om mani padme hum', normalisedTokens: []);

void main() {
  group('SessionCheckpointer', () {
    late SessionController controller;
    late FakeCountingEngine engine;
    late InMemoryCheckpointStore store;
    late SessionCheckpointer checkpointer;
    late int ids;

    void build() {
      ids = 0;
      engine = FakeCountingEngine();
      controller = SessionController(engine: engine);
      store = InMemoryCheckpointStore();
      checkpointer = SessionCheckpointer(
        controller: controller,
        store: store,
        snapshot: snapshot,
        newId: () => 'cp-${++ids}',
      );
    }

    tearDown(() {
      checkpointer.dispose();
      controller.dispose();
    });

    test('does nothing while the count is zero and no engine is running', () {
      fakeAsync((async) {
        build();
        async.elapse(const Duration(minutes: 1));

        expect(store.writes, 0);
        expect(store.clears, 0);
        expect(checkpointer.isTracking, isFalse);
      });
    });

    test('checkpoints immediately on the first count', () {
      fakeAsync((async) {
        build();
        controller.incrementManual();
        async.flushMicrotasks();

        expect(store.writes, 1);
        expect(store.current?.finalCount, 1);
        expect(store.current?.completed, isFalse);
        expect(checkpointer.isTracking, isTrue);
      });
    });

    test('writes at most once per interval while counts arrive', () {
      fakeAsync((async) {
        build();
        controller.incrementManual();
        async.flushMicrotasks();
        expect(store.writes, 1);

        for (var i = 0; i < 20; i++) {
          controller.incrementManual();
        }
        async.elapse(const Duration(seconds: 9));
        expect(store.writes, 1, reason: 'no tick has fired yet');

        async.elapse(const Duration(seconds: 1));
        expect(store.writes, 2);
        expect(store.current?.finalCount, 21);

        async.elapse(const Duration(seconds: 10));
        expect(store.writes, 2, reason: 'nothing changed, nothing written');

        controller.incrementManual();
        async.elapse(const Duration(seconds: 10));
        expect(store.writes, 3);
        expect(store.current?.finalCount, 22);
      });
    });

    test('keeps the same checkpoint id for the life of a session', () {
      fakeAsync((async) {
        build();
        controller.incrementManual();
        async.flushMicrotasks();
        final first = store.current?.id;

        controller.incrementManual();
        async.elapse(const Duration(seconds: 10));

        expect(store.current?.id, first);
        expect(checkpointer.checkpointId, first);
      });
    });

    test('a status hop that changes no content writes nothing', () {
      fakeAsync((async) {
        build();
        controller.incrementManual();
        async.flushMicrotasks();
        expect(store.writes, 1);

        // Status is not persisted, so churning it cannot make the stored
        // record any more accurate. This used to cost a Hive write per
        // transition, and reconnect storms produce a lot of them.
        for (final status in [
          EngineStatus.connecting,
          EngineStatus.reconnecting,
          EngineStatus.degraded,
          EngineStatus.live,
        ]) {
          engine.emitStatus(status);
          async.flushMicrotasks();
        }
        async.elapse(const Duration(minutes: 1));

        expect(store.writes, 1);
      });
    });

    test('a phrase change is content, so it is written on the next tick', () {
      fakeAsync((async) {
        build();
        controller.incrementManual();
        async.flushMicrotasks();
        expect(store.writes, 1);
        expect(store.current?.phrase, isNull);

        controller.startSession(phrase);
        async.elapse(const Duration(seconds: 10));

        expect(store.writes, 2);
        expect(store.current?.phrase, phrase.raw);
        expect(store.current?.finalCount, 1);
      });
    });

    test('idle tracking leaves no timer running', () {
      fakeAsync((async) {
        build();
        controller.incrementManual();
        async.flushMicrotasks();

        // The write is done and nothing has changed since, so there is nothing
        // left to fire. A periodic timer used to tick every 10 s for the whole
        // session regardless.
        expect(async.periodicTimerCount, 0);
        expect(async.nonPeriodicTimerCount, 0);
      });
    });

    test('tracks a voice session even before the first detection', () {
      fakeAsync((async) {
        build();
        controller.startSession(phrase);
        async.flushMicrotasks();

        expect(checkpointer.isTracking, isTrue);
        expect(store.writes, 1);
        expect(store.current?.finalCount, 0);
      });
    });

    test('clears its own checkpoint when the session is reset', () {
      fakeAsync((async) {
        build();
        controller.incrementManual();
        async.flushMicrotasks();
        expect(store.current, isNotNull);

        controller.reset();
        async.flushMicrotasks();

        expect(store.current, isNull);
        expect(store.clears, 1);
        expect(checkpointer.isTracking, isFalse);

        async.elapse(const Duration(minutes: 1));
        expect(store.writes, 1, reason: 'timer must be cancelled');
      });
    });

    test('starts a fresh checkpoint id for the next session', () {
      fakeAsync((async) {
        build();
        controller.incrementManual();
        async.flushMicrotasks();
        final first = store.current?.id;

        controller.reset();
        async.flushMicrotasks();
        controller.incrementManual();
        async.flushMicrotasks();

        expect(store.current?.id, isNot(first));
      });
    });

    test('clear() removes the checkpoint and later progress re-creates it', () {
      fakeAsync((async) {
        build();
        controller.incrementManual();
        controller.incrementManual();
        async.flushMicrotasks();

        checkpointer.clear();
        async.flushMicrotasks();
        expect(store.current, isNull);

        async.elapse(const Duration(seconds: 10));
        expect(store.current, isNull, reason: 'nothing changed since save');

        controller.incrementManual();
        async.elapse(const Duration(seconds: 10));
        expect(store.current?.finalCount, 3);
      });
    });

    test('flush() writes regardless of the interval', () {
      fakeAsync((async) {
        build();
        controller.incrementManual();
        async.flushMicrotasks();
        controller.incrementManual();

        checkpointer.flush();
        async.flushMicrotasks();

        expect(store.writes, 2);
        expect(store.current?.finalCount, 2);
      });
    });

    test('clear() leaves a later status change alone', () {
      fakeAsync((async) {
        build();
        controller.incrementManual();
        async.flushMicrotasks();
        expect(store.writes, 1);

        // Saving clears the checkpoint but does not zero the on-screen count.
        checkpointer.clear();
        async.flushMicrotasks();
        expect(store.current, isNull);

        // Regression: stopping the engine after a save re-checkpointed the
        // already-saved total, so the next launch offered to recover a session
        // that was sitting in history.
        engine.emitStatus(EngineStatus.idle);
        async.elapse(const Duration(minutes: 1));

        expect(store.current, isNull);
        expect(store.writes, 1);
      });
    });

    test('dispose stops listening and cancels the timer', () {
      fakeAsync((async) {
        build();
        controller.incrementManual();
        async.flushMicrotasks();

        checkpointer.dispose();
        controller.incrementManual();
        async.elapse(const Duration(minutes: 1));

        expect(store.writes, 1);
      });
    });
  });
}
