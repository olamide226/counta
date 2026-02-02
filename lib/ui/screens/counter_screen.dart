import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/enums.dart';
import '../../state/providers/counter_provider.dart';
import '../../state/providers/settings_provider.dart';
import '../sheets/alert_config_sheet.dart';
import '../sheets/save_session_sheet.dart';
import '../sheets/sound_mode_sheet.dart';
import '../widgets/count_display.dart';
import '../widgets/quick_controls_bar.dart';
import '../widgets/resizable_tap_layout.dart';
import '../widgets/tap_zone.dart';
import 'sessions_screen.dart';
import 'settings_screen.dart';

class CounterScreen extends ConsumerWidget {
  const CounterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counter = ref.watch(counterProvider);
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Counta'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SessionsScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: SafeArea(
        child: ResizableTapLayout(
          tapChild: TapZone(
            onTap: () => ref.read(counterProvider.notifier).increment(),
          ),
          infoChild: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                CountDisplay(count: counter.count),
                const SizedBox(height: 16),
                QuickControlsBar(
                  onReset: () =>
                      _handleReset(context, ref, settings.confirmReset),
                  onUndo: () => ref.read(counterProvider.notifier).decrement(),
                  onSave: () => showSaveSessionSheet(context),
                  onAlertConfig: () => showAlertConfigSheet(context),
                  onSoundMode: () => showSoundModeSheet(context),
                  soundModeIcon: _getSoundModeIcon(settings.soundMode),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _handleReset(BuildContext context, WidgetRef ref, bool confirmReset) {
    if (confirmReset) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Reset Count?'),
          content: const Text('This will reset your current count to zero.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                ref.read(counterProvider.notifier).reset();
                Navigator.of(context).pop();
              },
              child: const Text('Reset'),
            ),
          ],
        ),
      );
    } else {
      ref.read(counterProvider.notifier).reset();
    }
  }

  IconData _getSoundModeIcon(SoundMode mode) {
    return switch (mode) {
      SoundMode.mute => Icons.volume_off,
      SoundMode.sound => Icons.volume_up,
      SoundMode.vibrate => Icons.vibration,
      SoundMode.soundAndVibrate => Icons.speaker_phone,
    };
  }
}
