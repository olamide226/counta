import 'package:flutter/material.dart';

/// Asks before signing this phone out. Returns true to go ahead.
Future<bool> confirmSignOut(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Sign out?'),
      content: const Text(
        'Your voice minutes stay in your account. Sign in again any time to '
        'use them on this phone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Sign out'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// Asks before deleting the account. Returns true to go ahead.
Future<bool> confirmDeleteAccount(BuildContext context) async {
  final scheme = Theme.of(context).colorScheme;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: Icon(Icons.delete_outline, color: scheme.error),
      title: const Text('Delete your account?'),
      content: const Text(
        'This deletes your account and any voice minutes left in it, and '
        "can't be undone.\n\nYour counts and saved sessions on this phone "
        'are kept.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
