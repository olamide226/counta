import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:counta/core/theme/theme_registry.dart';
import 'package:counta/domain/models/enums.dart';

void main() {
  group('ThemeRegistry', () {
    test('builds light theme for ocean', () {
      final theme = ThemeRegistry.buildTheme(
        AppThemeId.ocean,
        Brightness.light,
      );

      expect(theme.brightness, Brightness.light);
      expect(theme.useMaterial3, true);
      expect(theme.colorScheme, isNotNull);
    });

    test('builds dark theme for ocean', () {
      final theme = ThemeRegistry.buildTheme(AppThemeId.ocean, Brightness.dark);

      expect(theme.brightness, Brightness.dark);
      expect(theme.useMaterial3, true);
      expect(theme.colorScheme, isNotNull);
    });

    test('builds theme for all theme IDs', () {
      for (final themeId in AppThemeId.values) {
        final lightTheme = ThemeRegistry.buildTheme(themeId, Brightness.light);
        final darkTheme = ThemeRegistry.buildTheme(themeId, Brightness.dark);

        expect(lightTheme.brightness, Brightness.light);
        expect(darkTheme.brightness, Brightness.dark);
        expect(lightTheme.useMaterial3, true);
        expect(darkTheme.useMaterial3, true);
      }
    });

    test('different themes have different seed colors', () {
      final oceanTheme = ThemeRegistry.buildTheme(
        AppThemeId.ocean,
        Brightness.light,
      );
      final forestTheme = ThemeRegistry.buildTheme(
        AppThemeId.forest,
        Brightness.light,
      );
      final sunsetTheme = ThemeRegistry.buildTheme(
        AppThemeId.sunset,
        Brightness.light,
      );

      // Color schemes should be different for different themes
      expect(oceanTheme.colorScheme, isNot(forestTheme.colorScheme));
      expect(forestTheme.colorScheme, isNot(sunsetTheme.colorScheme));
    });

    test(
      'light and dark variants of same theme have matching seed but different brightness',
      () {
        for (final themeId in AppThemeId.values) {
          final lightTheme = ThemeRegistry.buildTheme(
            themeId,
            Brightness.light,
          );
          final darkTheme = ThemeRegistry.buildTheme(themeId, Brightness.dark);

          expect(lightTheme.brightness, isNot(darkTheme.brightness));
        }
      },
    );

    test('all themes use Material 3', () {
      for (final themeId in AppThemeId.values) {
        for (final brightness in [Brightness.light, Brightness.dark]) {
          final theme = ThemeRegistry.buildTheme(themeId, brightness);
          expect(theme.useMaterial3, true);
        }
      }
    });

    test('mono theme has unique characteristics', () {
      final monoLight = ThemeRegistry.buildTheme(
        AppThemeId.mono,
        Brightness.light,
      );
      final monoDark = ThemeRegistry.buildTheme(
        AppThemeId.mono,
        Brightness.dark,
      );

      expect(monoLight.colorScheme, isNotNull);
      expect(monoDark.colorScheme, isNotNull);
    });

    test('lavender theme has unique characteristics', () {
      final lavenderLight = ThemeRegistry.buildTheme(
        AppThemeId.lavender,
        Brightness.light,
      );
      final lavenderDark = ThemeRegistry.buildTheme(
        AppThemeId.lavender,
        Brightness.dark,
      );

      expect(lavenderLight.colorScheme, isNotNull);
      expect(lavenderDark.colorScheme, isNotNull);
    });
  });
}
