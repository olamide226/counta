import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/date_format.dart';
import '../../domain/models/count_session.dart';
import '../../state/providers/session_recovery.dart';
import '../widgets/session_summary_card.dart';
import 'counta_sheet.dart';

/// Offered on launch when the previous run ended without saving or clearing
/// its session (requirement 7.2).
class RecoverSessionSheet extends ConsumerWidget {
  const RecoverSessionSheet({super.key, required this.checkpoint});

  final CountSession checkpoint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final recovery = ref.read(sessionRecoveryProvider);

    /// Runs one of the three decisions and closes the sheet.
    ///
    /// The sheet cannot be dismissed, so a failure here would trap the user
    /// behind it with no way out and no explanation. Every path closes.
    Future<void> run(Future<void> Function() action) async {
      try {
        await action();
      } catch (error) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not finish that: $error'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } finally {
        if (context.mounted) Navigator.of(context).pop();
      }
    }

    return PopScope(
      // The sheet is already undismissable by tap and drag; without this the
      // Android back gesture still closed it, losing the checkpoint without a
      // decision.
      canPop: false,
      child: CountaSheetBody(
        children: [
          Text('Recover session?', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'Counta closed before this session was saved. '
            'The count was last checkpointed at '
            '${checkpoint.endedAt.asSessionTimestamp}.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          SessionSummaryCard(
            title: checkpoint.mantra,
            total: checkpoint.finalCount,
            voiceCount: checkpoint.voiceCount,
            manualCount: checkpoint.manualCount,
            isVoiceSession: checkpoint.isVoiceSession,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => run(() => recovery.save(checkpoint)),
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save to history'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => run(() async => recovery.resume(checkpoint)),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Continue counting'),
          ),
          const SizedBox(height: 8),
          TextButton(
            // Nothing to undo: the checkpoint left the store at startup, so
            // dismissing this sheet is the discard.
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
  }
}

Future<void> showRecoverSessionSheet(
  BuildContext context,
  CountSession checkpoint,
) {
  return showCountaSheet<void>(
    context: context,
    dismissible: false,
    builder: (_) => RecoverSessionSheet(checkpoint: checkpoint),
  );
}
