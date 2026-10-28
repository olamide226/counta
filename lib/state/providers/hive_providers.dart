import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/hive/hive_init.dart';
import '../../data/repositories/open_block_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../domain/counting/open_block_store.dart';
import '../../data/repositories/phrase_history_repository.dart';
import '../../data/repositories/session_checkpoint_repository.dart';
import '../../data/repositories/sessions_repository.dart';

final hiveInitProvider = FutureProvider<void>((ref) async {
  await initHive();
});

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  ref.watch(hiveInitProvider);
  return createSettingsRepository();
});

final sessionsRepositoryProvider = Provider<SessionsRepository>((ref) {
  ref.watch(hiveInitProvider);
  return createSessionsRepository();
});

final sessionCheckpointRepositoryProvider = Provider<SessionCheckpointStore>((
  ref,
) {
  ref.watch(hiveInitProvider);
  return createSessionCheckpointRepository();
});

/// Recent phrase setups, for the one-tap chips in phrase setup.
final phraseHistoryRepositoryProvider = Provider<PhraseHistoryRepository>((
  ref,
) {
  ref.watch(hiveInitProvider);
  return createPhraseHistoryRepository();
});

/// Paid voice blocks this device holds, so a run killed mid-session can be
/// settled when the app next opens.
final openBlockStoreProvider = Provider<OpenBlockStore>((ref) {
  ref.watch(hiveInitProvider);
  return createOpenBlockStore();
});
