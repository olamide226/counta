import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/theme_registry.dart';
import 'state/providers/counter_provider.dart';
import 'state/providers/session_recovery.dart';
import 'state/providers/settings_provider.dart';
import 'ui/screens/counter_screen.dart';
import 'ui/sheets/voice_disclosure_sheet.dart';

/// Lets the disclosure gate find a navigator: the gate is owned by
/// `SessionController`, which has no `BuildContext` of its own.
final _navigatorKey = GlobalKey<NavigatorState>();

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    // Starts the recovery sequence here, in composition: the previous run's
    // checkpoint has to be taken out of the store — and the checkpointer
    // attached — before any screen can count. CounterScreen only reacts.
    ref.watch(sessionStartupProvider);

    // The controller owns the voice lifecycle but must not import the UI
    // layer, so the shell hands it the disclosure gate. Assigning on every
    // build is idempotent and keeps the closure bound to a live `ref`.
    ref.read(sessionControllerProvider).disclosureGate = () =>
        _confirmVoiceDisclosure(ref);

    return MaterialApp(
      title: 'Counta',
      navigatorKey: _navigatorKey,
      theme: ThemeRegistry.buildTheme(settings.themeId, Brightness.light),
      darkTheme: ThemeRegistry.buildTheme(settings.themeId, Brightness.dark),
      themeMode: ThemeRegistry.toThemeMode(settings.themeModeChoice),
      home: const CounterScreen(),
    );
  }
}

/// Shows the one-time third-party audio disclosure, if it is still owed, and
/// records acceptance. Returns false when the user declines, which aborts the
/// voice session before any engine is built.
Future<bool> _confirmVoiceDisclosure(WidgetRef ref) async {
  if (ref.read(settingsProvider).voiceDisclosureSeen) return true;

  final context = _navigatorKey.currentContext;
  if (context == null) return false;

  final accepted = await showVoiceDisclosureSheet(context);
  if (!accepted) return false;

  // Only after an explicit acceptance: dismissing must leave it owed.
  await ref.read(settingsProvider.notifier).markVoiceDisclosureSeen();
  return true;
}
