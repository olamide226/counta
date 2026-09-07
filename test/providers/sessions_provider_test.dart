import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:counta/data/repositories/sessions_repository.dart';
import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/domain/models/count_session.dart';
import 'package:counta/state/providers/counter_provider.dart';
import 'package:counta/state/providers/hive_providers.dart';
import 'package:counta/state/providers/session_checkpointer.dart';
import 'package:counta/state/providers/sessions_provider.dart';
import 'package:counta/state/providers/settings_provider.dart';

import '../helpers/checkpoint_store.dart';
import '../helpers/fake_counting_engine.dart';
import '../helpers/mock_repositories.dart';
import '../helpers/session_factory.dart';
import '../helpers/temp_hive.dart';

/// Runs [body] against the real `sessionsProvider` — the checkpoint-retiring
/// one — backed by a throwaway Hive box.
Future<void> withSessions(
  InMemoryCheckpointStore store,
  Future<void> Function(ProviderContainer container) body,
) {
  return withTempHive(() async {
    final box = await Hive.openBox<CountSession>('sessions_provider_test');
    final container = ProviderContainer(
      overrides: [
        sessionsRepositoryProvider.overrideWithValue(SessionsRepository(box)),
        sessionCheckpointRepositoryProvider.overrideWithValue(store),
        settingsProvider.overrideWith(
          (ref) => SettingsNotifier(MockSettingsRepository()),
        ),
      ],
    );
    try {
      await body(container);
    } finally {
      container.dispose();
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionsNotifier', () {
    test('saving retires the checkpoint', () async {
      final store = InMemoryCheckpointStore();

      await withSessions(store, (container) async {
        final controller = container.read(sessionControllerProvider);
        container.read(sessionCheckpointerProvider);

        controller.incrementManual();
        await container.read(sessionCheckpointerProvider).flush();
        expect(store.current, isNotNull);

        await container
            .read(sessionsProvider.notifier)
            .saveSession(testSession(id: 'saved', completed: true));

        // Neither the save sheet nor recovery clears any more: saving is the
        // one place that knows the counts are safe in history.
        expect(store.current, isNull);
        expect(container.read(sessionsProvider), hasLength(1));
      });
    });

    test('a status change after a save does not re-checkpoint', () async {
      final store = InMemoryCheckpointStore();

      await withSessions(store, (container) async {
        final engine = FakeCountingEngine();
        final controller = container.read(sessionControllerProvider);
        controller.setEngine(engine);
        container.read(sessionCheckpointerProvider);

        controller.incrementManual();
        await container.read(sessionCheckpointerProvider).flush();

        await container
            .read(sessionsProvider.notifier)
            .saveSession(testSession(id: 'saved', completed: true));
        expect(store.current, isNull);

        // Regression: saving then stopping wrote the already-saved counts
        // straight back, so the next launch offered to recover a session that
        // was sitting in history.
        engine.emitStatus(EngineStatus.live);
        engine.emitStatus(EngineStatus.idle);
        await Future<void>.delayed(Duration.zero);

        expect(store.current, isNull);
      });
    });
  });
}
