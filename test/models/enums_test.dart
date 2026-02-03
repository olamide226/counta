import 'package:flutter_test/flutter_test.dart';
import 'package:counta/domain/models/enums.dart';

void main() {
  group('SoundMode', () {
    test('has all expected values', () {
      expect(SoundMode.values.length, 4);
      expect(SoundMode.values, contains(SoundMode.mute));
      expect(SoundMode.values, contains(SoundMode.sound));
      expect(SoundMode.values, contains(SoundMode.vibrate));
      expect(SoundMode.values, contains(SoundMode.soundAndVibrate));
    });

    test('can be compared', () {
      expect(SoundMode.mute, SoundMode.mute);
      expect(SoundMode.sound, isNot(SoundMode.vibrate));
    });

    test('can be used in switch statements', () {
      String getDescription(SoundMode mode) {
        switch (mode) {
          case SoundMode.mute:
            return 'Silent';
          case SoundMode.sound:
            return 'Sound';
          case SoundMode.vibrate:
            return 'Vibrate';
          case SoundMode.soundAndVibrate:
            return 'Sound + Vibrate';
        }
      }

      expect(getDescription(SoundMode.mute), 'Silent');
      expect(getDescription(SoundMode.sound), 'Sound');
      expect(getDescription(SoundMode.vibrate), 'Vibrate');
      expect(getDescription(SoundMode.soundAndVibrate), 'Sound + Vibrate');
    });
  });

  group('ThemeModeChoice', () {
    test('has all expected values', () {
      expect(ThemeModeChoice.values.length, 3);
      expect(ThemeModeChoice.values, contains(ThemeModeChoice.light));
      expect(ThemeModeChoice.values, contains(ThemeModeChoice.dark));
      expect(ThemeModeChoice.values, contains(ThemeModeChoice.system));
    });

    test('can be compared', () {
      expect(ThemeModeChoice.light, ThemeModeChoice.light);
      expect(ThemeModeChoice.dark, isNot(ThemeModeChoice.light));
    });
  });

  group('AppThemeId', () {
    test('has all expected values', () {
      expect(AppThemeId.values.length, 5);
      expect(AppThemeId.values, contains(AppThemeId.ocean));
      expect(AppThemeId.values, contains(AppThemeId.forest));
      expect(AppThemeId.values, contains(AppThemeId.sunset));
      expect(AppThemeId.values, contains(AppThemeId.mono));
      expect(AppThemeId.values, contains(AppThemeId.lavender));
    });

    test('can be compared', () {
      expect(AppThemeId.ocean, AppThemeId.ocean);
      expect(AppThemeId.forest, isNot(AppThemeId.sunset));
    });

    test('default theme is ocean', () {
      // Based on AppSettings.defaults()
      expect(AppThemeId.ocean, AppThemeId.values.first);
    });
  });
}
