import 'package:flutter_test/flutter_test.dart';
import 'package:counta/domain/models/app_settings.dart';
import 'package:counta/domain/models/enums.dart';

void main() {
  group('AppSettings', () {
    test('defaults factory creates correct values', () {
      final settings = AppSettings.defaults();

      expect(settings.themeModeChoice, ThemeModeChoice.system);
      expect(settings.themeId, AppThemeId.ocean);
      expect(settings.soundMode, SoundMode.vibrate);
      expect(settings.defaultThreshold, 100);
      expect(settings.defaultRepeatInterval, 100);
      expect(settings.tapZoneRatio, 0.75);
      expect(settings.confirmReset, true);
      expect(settings.keepScreenOn, false);
    });

    test('copyWith updates specific fields', () {
      final original = AppSettings.defaults();

      final updated = original.copyWith(
        soundMode: SoundMode.mute,
        defaultThreshold: 100,
      );

      expect(updated.soundMode, SoundMode.mute);
      expect(updated.defaultThreshold, 100);
      // Other fields remain unchanged
      expect(updated.themeModeChoice, ThemeModeChoice.system);
      expect(updated.themeId, AppThemeId.ocean);
      expect(updated.defaultRepeatInterval, 100);
      expect(updated.tapZoneRatio, 0.75);
      expect(updated.confirmReset, true);
      expect(updated.keepScreenOn, false);
    });

    test('copyWith with no parameters returns identical settings', () {
      final original = AppSettings.defaults();
      final copy = original.copyWith();

      expect(copy.themeModeChoice, original.themeModeChoice);
      expect(copy.themeId, original.themeId);
      expect(copy.soundMode, original.soundMode);
      expect(copy.defaultThreshold, original.defaultThreshold);
      expect(copy.defaultRepeatInterval, original.defaultRepeatInterval);
      expect(copy.tapZoneRatio, original.tapZoneRatio);
      expect(copy.confirmReset, original.confirmReset);
      expect(copy.keepScreenOn, original.keepScreenOn);
    });

    test('copyWith preserves default threshold when not specified', () {
      final settings = AppSettings.defaults();

      final updated = settings.copyWith(soundMode: SoundMode.mute);

      expect(updated.defaultThreshold, 100);
      expect(updated.defaultRepeatInterval, 100);
      expect(updated.soundMode, SoundMode.mute);
    });

    test('can update all theme-related settings', () {
      final original = AppSettings.defaults();

      final updated = original.copyWith(
        themeModeChoice: ThemeModeChoice.dark,
        themeId: AppThemeId.lavender,
      );

      expect(updated.themeModeChoice, ThemeModeChoice.dark);
      expect(updated.themeId, AppThemeId.lavender);
    });

    test('tapZoneRatio accepts valid range', () {
      final settings = AppSettings.defaults().copyWith(tapZoneRatio: 0.5);
      expect(settings.tapZoneRatio, 0.5);

      final settings2 = AppSettings.defaults().copyWith(tapZoneRatio: 0.9);
      expect(settings2.tapZoneRatio, 0.9);
    });

    test('boolean settings can be toggled', () {
      final original = AppSettings.defaults();

      final updated = original.copyWith(
        confirmReset: false,
        keepScreenOn: true,
      );

      expect(updated.confirmReset, false);
      expect(updated.keepScreenOn, true);
    });
  });
}
