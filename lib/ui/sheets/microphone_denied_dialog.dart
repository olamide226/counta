import 'package:flutter/material.dart';

/// Explains why voice counting cannot start without the microphone and offers
/// the system settings page, which is where a refused permission gets fixed.
///
/// [onOpenSettings] should return false when the platform could not open the
/// settings page, so the user is told instead of left waiting.
Future<void> showMicrophoneDeniedDialog(
  BuildContext context, {
  required Future<bool> Function() onOpenSettings,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(Icons.mic_off),
      title: const Text('Microphone access needed'),
      content: const Text(
        'Voice counting listens for your phrase through the microphone, and '
        'Counta does not have permission to use it.\n\n'
        'Allow microphone access in Settings, then start the voice session '
        'again. Tap counting still works without it.',
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
                    'Could not open Settings. Enable the microphone for '
                    'Counta in your system settings.',
                  ),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          },
          child: const Text('Open Settings'),
        ),
      ],
    ),
  );
}
