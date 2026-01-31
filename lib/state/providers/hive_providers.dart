import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/hive/hive_init.dart';
import '../../data/repositories/settings_repository.dart';
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
