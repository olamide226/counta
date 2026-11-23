import 'package:flutter/material.dart';

/// Offers to show the live count on the lock screen and in the status bar
/// (an Android 16+ Live Update). Android has no permission dialog for this,
/// only a per-app switch, so "Turn on" opens that switch.
///
/// [onOpenSettings] returns false when no settings page could be opened.
Future<void> showLiveUpdatesDialog(
  BuildContext context, {
  required Future<bool> Function() onOpenSettings,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(Icons.lock_clock),
      title: const Text('See your count on the lock screen?'),
      content: const Text(
        'While voice counting runs, Counta can show your count in the status '
        'bar and on the lock screen.\n\n'
        'Turn on Live Updates for Counta on the next screen. Counting works '
        'the same either way.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () async {
            final navigator = Navigator.of(dialogContext);
            final messenger = ScaffoldMessenger.of(context);
            final opened = await onOpenSettings();
            navigator.pop();
            if (!opened) {
              messenger.showSnackBar(
                const SnackBar(
                  content: Text(
                    'Could not open Settings. Turn on Live Updates under '
                    'Settings → Notifications → Counta.',
                  ),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          },
          child: const Text('Turn on'),
        ),
      ],
    ),
  );
}
