import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:counta/domain/models/count_session.dart';
import 'package:counta/domain/models/enums.dart';
import 'package:counta/state/providers/counter_provider.dart';
import 'package:counta/state/providers/hive_providers.dart';
import 'package:counta/state/providers/session_recovery.dart';
import 'package:counta/state/providers/sessions_provider.dart';
import 'package:counta/state/providers/settings_provider.dart';

import '../helpers/checkpoint_store.dart';
import '../helpers/mock_repositories.dart';

CountSession checkpoint({int count = 17}) {
  return CountSession(
    id: 'cp',
    mantra: 'hare krishna',
    startedAt: DateTime(2026, 5, 5, 6),
    endedAt: DateTime(2026, 5, 5, 6, 20),
    finalCount: count,
    soundMode: SoundMode.mute,
    themeModeChoice: ThemeModeChoice.system,
    themeId: AppThemeId.ocean,
    phrase: 'hare krishna',
    voiceCount: count,
    manualCount: 0,
    completed: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pendingRecovery', () {
    test('is null when no checkpoint exists', () {
      expect(pendingRecovery(InMemoryCheckpointStore()), isNull);
    });

    test('ignores a checkpoint at zero', () {
      final store = InMemoryCheckpointStore()..current = checkpoint(count: 0);
      expect(pendingRecovery(store), isNull);
    });

    test('returns a checkpoint with progress', () {
      final store = InMemoryCheckpointStore()..current = checkpoint();
      expect(pendingRecovery(store)?.finalCount, 17);
    });
  });

  group('SessionRecovery', () {
    late InMemoryCheckpointStore store;
    late InMemorySessionsRepository sessions;
    late ProviderContainer container;

    setUp(() {
      store = InMemoryCheckpointStore()..current = checkpoint();
      sessions = InMemorySessionsRepository();
      container = ProviderContainer(
        overrides: [
          sessionCheckpointRepositoryProvider.overrideWithValue(store),
          sessionsProvider.overrideWith((ref) => SessionsNotifier(sessions)),
          settingsProvider.overrideWith(
            (ref) => SettingsNotifier(MockSettingsRepository()),
          ),
        ],
      );
    });

    tearDown(() => container.dispose());

    test('pending surfaces the stored checkpoint', () {
      expect(container.read(sessionRecoveryProvider).pending?.id, 'cp');
    });

    test('save writes a recovered record to history and clears', () async {
      final recovery = container.read(sessionRecoveryProvider);
      await recovery.save(recovery.pending!);

      final saved = sessions.getSession('cp');
      expect(saved, isNotNull);
      expect(saved!.completed, isFalse);
      expect(saved.finalCount, 17);
      expect(saved.voiceCount, 17);
      expect(store.current, isNull);
      expect(container.read(sessionsProvider).single.id, 'cp');
    });

    test('discard clears without saving', () async {
      await container.read(sessionRecoveryProvider).discard();

      expect(store.current, isNull);
      expect(sessions.getAllSessions(), isEmpty);
    });

    test(
      'resume seeds the live counter and hands over to the checkpointer',
      () async {
        final recovery = container.read(sessionRecoveryProvider);
        await recovery.resume(recovery.pending!);

        expect(container.read(counterProvider).count, 17);
        expect(container.read(sessionControllerProvider).total, 17);
        expect(sessions.getAllSessions(), isEmpty);

        // The old checkpoint is gone; the resumed session is tracked afresh
        // under a new identity so a second crash is still recoverable.
        final fresh = store.current;
        expect(fresh, isNotNull);
        expect(fresh!.id, isNot('cp'));
        expect(fresh.finalCount, 17);
        expect(fresh.completed, isFalse);
      },
    );
  });
}
