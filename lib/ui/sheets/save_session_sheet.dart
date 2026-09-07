import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/count_session.dart';
import '../../state/providers/counter_provider.dart';
import '../../state/providers/session_checkpointer.dart';
import '../../state/providers/sessions_provider.dart';
import '../../state/providers/settings_provider.dart';
import '../../state/providers/services_provider.dart';

class SaveSessionSheet extends ConsumerStatefulWidget {
  const SaveSessionSheet({super.key});

  @override
  ConsumerState<SaveSessionSheet> createState() => _SaveSessionSheetState();
}

class _SaveSessionSheetState extends ConsumerState<SaveSessionSheet> {
  final _mantraController = TextEditingController();
  final _notesController = TextEditingController();
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // Save a voice session without retyping what you just spent it chanting.
    final phrase = ref.read(sessionControllerProvider).activePhrase;
    if (phrase != null) {
      _mantraController.text = phrase.raw;
    }
  }

  @override
  void dispose() {
    _mantraController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final counter = ref.watch(counterProvider);
    final session = ref.watch(sessionControllerProvider);
    final phrase = session.activePhrase;
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Save Session',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text('Count: ${counter.count}', style: theme.textTheme.titleMedium),
          if (phrase != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.graphic_eq_rounded,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '“${phrase.raw}”',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${session.voiceCount} by voice · '
                          '${session.manualCount} by tap',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (_errorMessage != null)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    color: Theme.of(context).colorScheme.error,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          TextField(
            controller: _mantraController,
            decoration: const InputDecoration(
              labelText: 'Mantra',
              hintText: 'Enter mantra name',
              border: OutlineInputBorder(),
            ),
            textCapitalization: TextCapitalization.words,
            onChanged: (_) {
              if (_errorMessage != null) {
                setState(() {
                  _errorMessage = null;
                });
              }
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notesController,
            decoration: const InputDecoration(
              labelText: 'Notes (optional)',
              hintText: 'Add any notes',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _saveSession, child: const Text('Save')),
        ],
      ),
    );
  }

  Future<void> _saveSession() async {
    final counter = ref.read(counterProvider);
    final settings = ref.read(settingsProvider);
    final controller = ref.read(sessionControllerProvider);
    final phrase = controller.activePhrase;

    final mantra = _mantraController.text.trim();
    if (mantra.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter a mantra name';
      });
      return;
    }

    setState(() {
      _errorMessage = null;
    });

    final session = CountSession(
      mantra: mantra,
      startedAt: counter.sessionStart,
      endedAt: DateTime.now(),
      finalCount: counter.count,
      threshold: counter.threshold,
      repeatInterval: counter.repeatInterval,
      soundMode: settings.soundMode,
      themeModeChoice: settings.themeModeChoice,
      themeId: settings.themeId,
      notes: _notesController.text.trim().isNotEmpty
          ? _notesController.text.trim()
          : null,
      phrase: phrase?.raw,
      voiceCount: phrase != null ? controller.voiceCount : null,
      manualCount: phrase != null ? controller.manualCount : null,
    );

    await ref.read(sessionsProvider.notifier).saveSession(session);

    // Saved cleanly, so there is nothing left to recover on next launch.
    await ref.read(sessionCheckpointerProvider).clear();

    // Clear any lingering notifications now that the session is saved.
    await ref.read(notificationServiceProvider).cancelAllNotifications();

    if (mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Session saved!')));
    }
  }
}

Future<void> showSaveSessionSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => const SaveSessionSheet(),
  );
}
