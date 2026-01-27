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
    return Wrap(
      spacing: 12,
      runSpacing: 12,
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
  }
}
