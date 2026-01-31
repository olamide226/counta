import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/count_session.dart';
import '../../state/providers/counter_provider.dart';
import '../../state/providers/sessions_provider.dart';
import '../../state/providers/settings_provider.dart';

class SaveSessionSheet extends ConsumerStatefulWidget {
  const SaveSessionSheet({super.key});

  @override
  ConsumerState<SaveSessionSheet> createState() => _SaveSessionSheetState();
}

class _SaveSessionSheetState extends ConsumerState<SaveSessionSheet> {
  final _mantraController = TextEditingController();
  final _notesController = TextEditingController();

  @override
  void dispose() {
    _mantraController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final counter = ref.watch(counterProvider);

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
          Text(
            'Count: ${counter.count}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _mantraController,
            decoration: const InputDecoration(
              labelText: 'Mantra',
              hintText: 'Enter mantra name',
              border: OutlineInputBorder(),
            ),
            textCapitalization: TextCapitalization.words,
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

    final mantra = _mantraController.text.trim();
    if (mantra.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a mantra name')),
      );
      return;
    }

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
    );

    await ref.read(sessionsProvider.notifier).saveSession(session);

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
