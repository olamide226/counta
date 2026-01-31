import 'package:flutter/material.dart';

class QuickControlsBar extends StatelessWidget {
  const QuickControlsBar({
    super.key,
    required this.onReset,
    required this.onSave,
    required this.onAlertConfig,
    required this.onSoundMode,
  });

  final VoidCallback onReset;
  final VoidCallback onSave;
  final VoidCallback onAlertConfig;
  final VoidCallback onSoundMode;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 320;

        if (isNarrow) {
          // Icon-only buttons for narrow screens
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.filled(
                onPressed: onReset,
                icon: const Icon(Icons.refresh_rounded),
                tooltip: 'Reset',
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                onPressed: onAlertConfig,
                icon: const Icon(Icons.notifications_active_outlined),
                tooltip: 'Alert Settings',
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                onPressed: onSoundMode,
                icon: const Icon(Icons.volume_up_outlined),
                tooltip: 'Sound Mode',
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: onSave,
                icon: const Icon(Icons.save_outlined),
                tooltip: 'Save Session',
              ),
            ],
          );
        }

        // Full buttons with labels for wider screens
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: onReset,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Reset'),
            ),
            OutlinedButton.icon(
              onPressed: onAlertConfig,
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Alert'),
            ),
            OutlinedButton.icon(
              onPressed: onSoundMode,
              icon: const Icon(Icons.volume_up_outlined),
              label: const Text('Sound'),
            ),
            FilledButton.tonalIcon(
              onPressed: onSave,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save'),
            ),
          ],
        );
      },
    );
  }
}
