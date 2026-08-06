import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/sound_mode_presentation.dart';

import '../../domain/models/enums.dart';
import '../../state/providers/settings_provider.dart';

class SoundModeSheet extends ConsumerWidget {
  const SoundModeSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final currentMode = settings.soundMode;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Sound Mode', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          ...SoundMode.values.map(
            (mode) => RadioListTile<SoundMode>(
              title: Text(mode.label),
              secondary: Icon(mode.icon),
              value: mode,
              groupValue: currentMode,
              onChanged: (value) {
                if (value != null) {
                  ref.read(settingsProvider.notifier).setSoundMode(value);
                  Navigator.of(context).pop();
                }
              },
            ),
          ),
        ],
      ),
    );
  }


}

Future<void> showSoundModeSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    builder: (_) => const SoundModeSheet(),
  );
}
