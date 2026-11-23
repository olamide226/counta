import 'package:flutter/material.dart';

import 'open_settings_dialog.dart';

/// Offers to show the live count on the lock screen and in the status bar
/// (an Android 16+ Live Update). Android has no permission dialog for this,
/// only a per-app switch, so "Turn on" opens that switch.
Future<void> showLiveUpdatesDialog(
  BuildContext context, {
  required Future<bool> Function() onOpenSettings,
}) => showOpenSettingsDialog(
  context,
  icon: Icons.lock_clock,
  title: 'See your count on the lock screen?',
  body:
      'While voice counting runs, Counta can show your count in the status '
      'bar and on the lock screen.\n\n'
      'Turn on Live Updates for Counta on the next screen. Counting works '
      'the same either way.',
  actionLabel: 'Turn on',
  failureText:
      'Could not open Settings. Turn on Live Updates under Settings → '
      'Notifications → Counta.',
  onOpenSettings: onOpenSettings,
);
