import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:counta/core/services/counting/tap_counting_engine.dart';
import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/domain/models/count_session.dart';
import 'package:counta/domain/models/enums.dart';
import 'package:counta/state/providers/session_checkpointer.dart';
import 'package:counta/state/providers/session_controller.dart';

import '../helpers/checkpoint_store.dart';

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
    late InMemoryCheckpointStore store;
    late SessionCheckpointer checkpointer;
    late int ids;

    void build() {
      ids = 0;
      controller = SessionController(engine: TapCountingEngine());
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

    test('never clears a checkpoint left by a previous process', () {
      fakeAsync((async) {
        build();
        store.current = snapshot(controller, 'stale');
        async.elapse(const Duration(minutes: 1));

        expect(store.current?.id, 'stale');
        expect(store.clears, 0);
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

    test('writes on every engine status transition', () {
      fakeAsync((async) {
        build();
        controller.incrementManual();
        async.flushMicrotasks();
        expect(store.writes, 1);

        // Tap engine goes idle -> live on start, live -> idle on stop.
        controller.startSession(phrase);
        async.flushMicrotasks();
        expect(store.writes, 2);
        expect(store.current?.phrase, phrase.raw);

        controller.stop();
        async.flushMicrotasks();
        expect(store.writes, 3);
        expect(store.current?.finalCount, 1);
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
