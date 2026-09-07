import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:counta/domain/models/count_session.dart';
import 'package:counta/domain/models/enums.dart';
import 'package:counta/state/providers/counter_provider.dart';
import 'package:counta/state/providers/hive_providers.dart';
import 'package:counta/state/providers/session_checkpointer.dart';
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

  late InMemoryCheckpointStore store;
  late InMemorySessionsRepository sessions;
  late ProviderContainer container;

  ProviderContainer build() {
    sessions = InMemorySessionsRepository();
    return ProviderContainer(
      overrides: [
        sessionCheckpointRepositoryProvider.overrideWithValue(store),
        sessionsProvider.overrideWith((ref) => SessionsNotifier(sessions)),
        settingsProvider.overrideWith(
          (ref) => SettingsNotifier(MockSettingsRepository()),
        ),
      ],
    );
  }

  tearDown(() => container.dispose());

  group('sessionStartupProvider', () {
    test('is null when no checkpoint exists', () async {
      store = InMemoryCheckpointStore();
      container = build();

      expect(await container.read(sessionStartupProvider.future), isNull);
    });

    test('ignores a checkpoint at zero', () async {
      store = InMemoryCheckpointStore()..current = checkpoint(count: 0);
      container = build();

      expect(await container.read(sessionStartupProvider.future), isNull);
    });

    test('surfaces a checkpoint with progress', () async {
      store = InMemoryCheckpointStore()..current = checkpoint();
      container = build();

      final pending = await container.read(sessionStartupProvider.future);
      expect(pending?.id, 'cp');
      expect(pending?.finalCount, 17);
    });

    test('empties the store, so a later write cannot clobber it', () async {
      store = InMemoryCheckpointStore()..current = checkpoint();
      container = build();

      await container.read(sessionStartupProvider.future);

      // Regression: recovery used to only read the checkpoint, so the first
      // count of this launch overwrote the crashed run's record before the
      // user had decided anything.
      expect(store.takes, 1);
      expect(store.current, isNull);
      expect(store.read(), isNull);
    });

    test('a count landing right after startup does not resurrect it', () async {
      store = InMemoryCheckpointStore()..current = checkpoint();
      container = build();

      final pending = await container.read(sessionStartupProvider.future);
      container.read(sessionControllerProvider).incrementManual();
      await Future<void>.delayed(Duration.zero);

      // Whatever the live session writes now is its own record, not the one
      // the user is still being asked about.
      expect(pending?.id, 'cp');
      expect(store.current?.id, isNot('cp'));
    });
  });

  group('SessionRecovery', () {
    setUp(() {
      store = InMemoryCheckpointStore()..current = checkpoint();
      container = build();
    });

    test('save writes a recovered record to history', () async {
      final pending = await container.read(sessionStartupProvider.future);
      await container.read(sessionRecoveryProvider).save(pending!);

      final saved = sessions.getSession('cp');
      expect(saved, isNotNull);
      expect(saved!.completed, isFalse);
      expect(saved.finalCount, 17);
      expect(saved.voiceCount, 17);
      expect(container.read(sessionsProvider).single.id, 'cp');
    });

    test('resume seeds the live counter and leaves history alone', () async {
      final pending = await container.read(sessionStartupProvider.future);
      container.read(sessionRecoveryProvider).resume(pending!);

      expect(container.read(counterProvider).count, 17);
      expect(container.read(sessionControllerProvider).total, 17);
      expect(sessions.getAllSessions(), isEmpty);
    });

    test('resume restores the whole session, not just the total', () async {
      final pending = await container.read(sessionStartupProvider.future);
      container.read(sessionRecoveryProvider).resume(pending!);

      final counter = container.read(counterProvider);
      final controller = container.read(sessionControllerProvider);

      // Regression: resuming used to seed the total as manual counts under a
      // brand-new start time with no phrase, so a recovered voice session came
      // back as a tap session that had just begun.
      expect(counter.sessionStart, DateTime(2026, 5, 5, 6));
      expect(counter.mantra, 'hare krishna');
      expect(controller.voiceCount, 17);
      expect(controller.manualCount, 0);
      expect(controller.activePhrase?.raw, 'hare krishna');
    });

    test('a resumed session checkpoints under its own name', () async {
      final pending = await container.read(sessionStartupProvider.future);
      container.read(sessionRecoveryProvider).resume(pending!);
      container.read(sessionControllerProvider).incrementManual();
      // Counts land on the next interval tick, so ask for the write directly
      // rather than waiting ten seconds of real time for it.
      await container.read(sessionCheckpointerProvider).flush();

      // Not the literal 'Recovered session' placeholder the snapshot used to
      // write for every checkpoint.
      expect(store.current?.mantra, 'hare krishna');
      expect(store.current?.phrase, 'hare krishna');
      expect(store.current?.voiceCount, 17);
      expect(store.current?.manualCount, 1);
      expect(store.current?.finalCount, 18);
    });
  });
}
