import 'package:hive/hive.dart';

import '../../domain/models/app_settings.dart';
import '../hive/hive_init.dart';

const String settingsKey = 'app_settings';

class SettingsRepository {
  final Box<AppSettings> _box;

  SettingsRepository(this._box);

  AppSettings getSettings() {
    return _box.get(settingsKey) ?? AppSettings.defaults();
  }

  Future<void> saveSettings(AppSettings settings) async {
    await _box.put(settingsKey, settings);
  }

  Future<void> updateSettings(AppSettings Function(AppSettings) updater) async {
    final current = getSettings();
    await saveSettings(updater(current));
  }
}

SettingsRepository createSettingsRepository() {
  return SettingsRepository(getSettingsBox());
}
