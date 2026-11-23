import 'package:flutter/material.dart';

import 'open_settings_dialog.dart';

/// Explains why voice counting cannot start without the microphone and offers
/// the system settings page, which is where a refused permission gets fixed.
///
/// [onOpenSettings] should return false when the platform could not open the
/// settings page, so the user is told instead of left waiting.
Future<void> showMicrophoneDeniedDialog(
  BuildContext context, {
  required Future<bool> Function() onOpenSettings,
}) => showOpenSettingsDialog(
  context,
  icon: Icons.mic_off,
  title: 'Microphone access needed',
  body:
      'Voice counting listens for your phrase through the microphone, and '
      'Counta does not have permission to use it.\n\n'
      'Allow microphone access in Settings, then start the voice session '
      'again. Tap counting still works without it.',
  actionLabel: 'Open Settings',
  failureText:
      'Could not open Settings. Enable the microphone for Counta in your '
      'system settings.',
  onOpenSettings: onOpenSettings,
);
