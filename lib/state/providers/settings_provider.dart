import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/app_settings.dart';
import '../../domain/models/enums.dart';
import 'hive_providers.dart';

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>((
  ref,
) {
  final repo = ref.watch(settingsRepositoryProvider);
  return SettingsNotifier(repo);
});

class SettingsNotifier extends StateNotifier<AppSettings> {
  final dynamic _repository;

  SettingsNotifier(this._repository) : super(_repository.getSettings());

  Future<void> setThemeModeChoice(ThemeModeChoice mode) async {
    final updated = state.copyWith(themeModeChoice: mode);
    state = updated;
    await _repository.saveSettings(updated);
  }

  Future<void> setThemeId(AppThemeId id) async {
    final updated = state.copyWith(themeId: id);
    state = updated;
    await _repository.saveSettings(updated);
  }

  Future<void> setSoundMode(SoundMode mode) async {
    final updated = state.copyWith(soundMode: mode);
    state = updated;
    await _repository.saveSettings(updated);
  }

  Future<void> setTapZoneRatio(double ratio) async {
    final updated = state.copyWith(tapZoneRatio: ratio);
    state = updated;
    await _repository.saveSettings(updated);
  }

  Future<void> setDefaultThreshold(int? threshold) async {
    final updated = state.copyWith(defaultThreshold: threshold);
    state = updated;
    await _repository.saveSettings(updated);
  }

  Future<void> setDefaultRepeatInterval(int? interval) async {
    final updated = state.copyWith(defaultRepeatInterval: interval);
    state = updated;
    await _repository.saveSettings(updated);
  }

  Future<void> toggleConfirmReset() async {
    final updated = state.copyWith(confirmReset: !state.confirmReset);
    state = updated;
    await _repository.saveSettings(updated);
  }

  Future<void> toggleKeepScreenOn() async {
    final updated = state.copyWith(keepScreenOn: !state.keepScreenOn);
    state = updated;
    await _repository.saveSettings(updated);
  }
}
