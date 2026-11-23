import 'package:flutter/material.dart';

/// A dialog whose fix lives in system settings: "Not now", or an action that
/// opens the settings page and tells the user where to go if it can't.
///
/// [onOpenSettings] returns false when no settings page could be opened, so
/// [failureText] is shown instead of leaving the user waiting.
Future<void> showOpenSettingsDialog(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String body,
  required String actionLabel,
  required String failureText,
  required Future<bool> Function() onOpenSettings,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: Icon(icon),
      title: Text(title),
      content: Text(body),
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
                SnackBar(
                  content: Text(failureText),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          },
          child: Text(actionLabel),
        ),
      ],
    ),
  );
}
