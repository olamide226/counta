import 'package:flutter/material.dart';

class QuickControlsBar extends StatelessWidget {
  const QuickControlsBar({
    super.key,
    required this.onReset,
    required this.onUndo,
    required this.onSave,
    required this.onAlertConfig,
    required this.onSoundMode,
    required this.soundModeIcon,
  });

  final VoidCallback onReset;
  final VoidCallback onUndo;
  final VoidCallback onSave;
  final VoidCallback onAlertConfig;
  final VoidCallback onSoundMode;
  final IconData soundModeIcon;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 320;

        if (isNarrow) {
          // Icon-only buttons for narrow screens.
          //
          // A Row here overflowed: the five 48px buttons plus their gaps need
          // 272px, but the resizable info pane can hand this widget far less
          // than that when the tap zone is dragged wide. Wrap reflows onto
          // extra rows instead of painting off the edge.
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              IconButton.filled(
                onPressed: onReset,
                icon: const Icon(Icons.refresh_rounded),
                tooltip: 'Reset',
              ),
              IconButton.outlined(
                onPressed: onUndo,
                icon: const Icon(Icons.undo),
                tooltip: 'Undo',
              ),
              IconButton.outlined(
                onPressed: onAlertConfig,
                icon: const Icon(Icons.notifications_active_outlined),
                tooltip: 'Alert',
              ),
              IconButton.outlined(
                onPressed: onSoundMode,
                icon: Icon(soundModeIcon),
                tooltip: 'Sound',
              ),
              IconButton.filledTonal(
                onPressed: onSave,
                icon: const Icon(Icons.save_outlined),
                tooltip: 'Save',
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
              onPressed: onUndo,
              icon: const Icon(Icons.undo),
              label: const Text('Undo'),
            ),
            OutlinedButton.icon(
              onPressed: onAlertConfig,
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Alert'),
            ),
            OutlinedButton.icon(
              onPressed: onSoundMode,
              icon: Icon(soundModeIcon),
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
