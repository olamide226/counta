import 'package:flutter/material.dart';

/// Asks before signing this phone out. Returns true to go ahead.
Future<bool> confirmSignOut(BuildContext context) => _confirm(
  context,
  title: 'Sign out?',
  body:
      'Your voice minutes stay in your account. Sign in again any time to '
      'use them on this phone.',
  action: 'Sign out',
);

/// Asks before deleting the account. Returns true to go ahead.
Future<bool> confirmDeleteAccount(BuildContext context) => _confirm(
  context,
  title: 'Delete your account?',
  body:
      'This deletes your account, any voice minutes left in it and its '
      "backed-up sessions, and can't be undone.\n\nThe sessions saved on this "
      'phone are kept.',
  action: 'Delete',
  icon: Icons.delete_outline,
  destructive: true,
);

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  IconData? icon,
  bool destructive = false,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: icon == null
          ? null
          : Icon(icon, color: destructive ? scheme.error : null),
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                )
              : null,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
