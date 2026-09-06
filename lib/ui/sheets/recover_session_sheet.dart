import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/count_session.dart';
import '../../state/providers/session_recovery.dart';

/// Offered on launch when the previous run ended without saving or clearing
/// its session (requirement 7.2).
class RecoverSessionSheet extends ConsumerWidget {
  const RecoverSessionSheet({super.key, required this.checkpoint});

  final CountSession checkpoint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final recovery = ref.read(sessionRecoveryProvider);
    final hasBreakdown =
        checkpoint.voiceCount != null || checkpoint.manualCount != null;

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
          Text('Recover session?', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'Counta closed before this session was saved. '
            'The count was last checkpointed at '
            '${_formatDateTime(checkpoint.endedAt)}.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  checkpoint.isVoiceSession
                      ? Icons.graphic_eq_rounded
                      : Icons.touch_app_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        checkpoint.mantra,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hasBreakdown
                            ? '${checkpoint.voiceCount ?? 0} by voice · '
                                  '${checkpoint.manualCount ?? 0} by tap'
                            : '${checkpoint.finalCount} counts',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${checkpoint.finalCount}',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () async {
              await recovery.save(checkpoint);
              if (context.mounted) Navigator.of(context).pop();
            },
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save to history'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              await recovery.resume(checkpoint);
              if (context.mounted) Navigator.of(context).pop();
            },
            icon: const Icon(Icons.play_arrow),
            label: const Text('Continue counting'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () async {
              await recovery.discard();
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('Discard'),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime date) {
    final hh = date.hour.toString().padLeft(2, '0');
    final mm = date.minute.toString().padLeft(2, '0');
    return '${date.day}/${date.month}/${date.year} $hh:$mm';
  }
}

Future<void> showRecoverSessionSheet(
  BuildContext context,
  CountSession checkpoint,
) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => RecoverSessionSheet(checkpoint: checkpoint),
  );
}
