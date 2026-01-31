import 'package:flutter/material.dart';

import '../../domain/models/enums.dart';

class ThemeRegistry {
  static Color getSeedColor(AppThemeId id) {
    return switch (id) {
      AppThemeId.ocean => const Color(0xFF5865F2),
      AppThemeId.forest => const Color(0xFF2E7D32),
      AppThemeId.sunset => const Color(0xFFE65100),
      AppThemeId.mono => const Color(0xFF424242),
      AppThemeId.lavender => const Color(0xFF7E57C2),
    };
  }

  static ThemeData buildTheme(AppThemeId id, Brightness brightness) {
    final seedColor = getSeedColor(id);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: brightness,
      ),
    );
  }

  static ThemeMode toThemeMode(ThemeModeChoice choice) {
    return switch (choice) {
      ThemeModeChoice.system => ThemeMode.system,
      ThemeModeChoice.light => ThemeMode.light,
      ThemeModeChoice.dark => ThemeMode.dark,
    };
  }
}
