import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/theme_registry.dart';
import 'state/providers/settings_provider.dart';
import 'ui/screens/counter_screen.dart';

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return MaterialApp(
      title: 'Counta',
      theme: ThemeRegistry.buildTheme(settings.themeId, Brightness.light),
      darkTheme: ThemeRegistry.buildTheme(settings.themeId, Brightness.dark),
      themeMode: ThemeRegistry.toThemeMode(settings.themeModeChoice),
      home: const CounterScreen(),
    );
  }
}
