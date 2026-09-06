import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:counta/data/repositories/settings_repository.dart';
import 'package:counta/domain/models/app_settings.dart';
import 'package:counta/domain/models/enums.dart';

/// Writes AppSettings the way the adapter did before `voiceDisclosureSeen`
/// existed (fields 0–7 only), so the upgrade path can be exercised against a
/// genuine legacy document rather than a hand-crafted map.
class LegacyAppSettingsAdapter extends TypeAdapter<AppSettings> {
  @override
  final int typeId = 0;

  @override
  AppSettings read(BinaryReader reader) => throw UnimplementedError();

  @override
  void write(BinaryWriter writer, AppSettings obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.themeModeChoice)
      ..writeByte(1)
      ..write(obj.themeId)
      ..writeByte(2)
      ..write(obj.soundMode)
      ..writeByte(3)
      ..write(obj.defaultThreshold)
      ..writeByte(4)
      ..write(obj.defaultRepeatInterval)
      ..writeByte(5)
      ..write(obj.tapZoneRatio)
      ..writeByte(6)
      ..write(obj.confirmReset)
      ..writeByte(7)
      ..write(obj.keepScreenOn);
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('counta_settings_test');
    Hive.init(tempDir.path);
    Hive.registerAdapter(SoundModeAdapter(), override: true);
    Hive.registerAdapter(ThemeModeChoiceAdapter(), override: true);
    Hive.registerAdapter(AppThemeIdAdapter(), override: true);
    Hive.registerAdapter(AppSettingsAdapter(), override: true);
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  group('AppSettings.voiceDisclosureSeen persistence', () {
    test('defaults to false', () {
      expect(AppSettings.defaults().voiceDisclosureSeen, isFalse);
    });

    test('round-trips through the settings repository', () async {
      final box = await Hive.openBox<AppSettings>('settings');
      final repo = SettingsRepository(box);

      expect(repo.getSettings().voiceDisclosureSeen, isFalse);

      await repo.saveSettings(
        repo.getSettings().copyWith(voiceDisclosureSeen: true),
      );
      await box.close();

      final reopened = await Hive.openBox<AppSettings>('settings');
      final loaded = SettingsRepository(reopened).getSettings();
      expect(loaded.voiceDisclosureSeen, isTrue);
      // Neighbouring fields survive the extra field.
      expect(loaded.themeId, AppThemeId.ocean);
      expect(loaded.keepScreenOn, isFalse);
    });

    test(
      'a settings document written before the field existed still loads',
      () async {
        Hive.registerAdapter(LegacyAppSettingsAdapter(), override: true);
        final legacyBox = await Hive.openBox<AppSettings>('settings');
        await legacyBox.put(
          settingsKey,
          AppSettings.defaults().copyWith(soundMode: SoundMode.mute),
        );
        await legacyBox.close();

        Hive.registerAdapter(AppSettingsAdapter(), override: true);
        final box = await Hive.openBox<AppSettings>('settings');
        final loaded = SettingsRepository(box).getSettings();

        expect(loaded.voiceDisclosureSeen, isFalse);
        expect(loaded.soundMode, SoundMode.mute);
      },
    );
  });
}
