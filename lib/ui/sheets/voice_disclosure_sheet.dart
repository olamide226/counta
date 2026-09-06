import 'package:flutter/material.dart';

/// One-time disclosure shown before the first voice session ever starts.
///
/// Returns true when the user accepts and false when they dismiss. Marking the
/// disclosure as seen is the caller's job, so the flag is only persisted after
/// an explicit acceptance.
Future<bool> showVoiceDisclosureSheet(BuildContext context) async {
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const VoiceDisclosureSheet(),
  );
  return accepted ?? false;
}

class VoiceDisclosureSheet extends StatelessWidget {
  const VoiceDisclosureSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.mic_none, size: 40, color: scheme.primary),
            const SizedBox(height: 12),
            Text(
              'Before you start voice counting',
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              'While a voice session is running, your microphone audio is '
              'streamed to Deepgram, a third-party speech recognition '
              'service, so the app can hear your phrase and count it.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            const _Point(
              icon: Icons.timer_outlined,
              text:
                  'Audio is sent only while a voice session you started '
                  'is active. Nothing is transmitted at any other time.',
            ),
            const _Point(
              icon: Icons.block,
              text:
                  'Audio is never saved to this device or stored by Counta. '
                  'Deepgram is instructed not to keep it for training.',
            ),
            const _Point(
              icon: Icons.visibility_outlined,
              text:
                  'A recording indicator stays visible for the whole '
                  'session.',
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('I understand, continue'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
