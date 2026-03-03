import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/count_session.dart';
import '../../domain/models/enums.dart';
import '../../state/providers/counter_provider.dart';
import '../../state/providers/sessions_provider.dart';

class SessionDetailScreen extends ConsumerWidget {
  const SessionDetailScreen({super.key, required this.session});

  final CountSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final duration = session.endedAt.difference(session.startedAt);

    return Scaffold(
      appBar: AppBar(
        title: Text(session.mantra),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete session',
            onPressed: () => _deleteSession(context, ref),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _buildStatCard(
            context,
            icon: Icons.numbers,
            label: 'Final Count',
            value: session.finalCount.toString(),
          ),
          const SizedBox(height: 16),
          _buildStatCard(
            context,
            icon: Icons.timer,
            label: 'Duration',
            value: _formatDuration(duration),
          ),
          const SizedBox(height: 16),
          _buildStatCard(
            context,
            icon: Icons.play_arrow,
            label: 'Started',
            value: _formatDateTime(session.startedAt),
          ),
          const SizedBox(height: 16),
          _buildStatCard(
            context,
            icon: Icons.stop,
            label: 'Ended',
            value: _formatDateTime(session.endedAt),
          ),
          if (session.threshold != null) ...[
            const SizedBox(height: 16),
            _buildStatCard(
              context,
              icon: Icons.flag,
              label: 'Threshold',
              value: session.threshold.toString(),
            ),
          ],
          if (session.repeatInterval != null) ...[
            const SizedBox(height: 16),
            _buildStatCard(
              context,
              icon: Icons.repeat,
              label: 'Repeat Interval',
              value: session.repeatInterval.toString(),
            ),
          ],
          const SizedBox(height: 16),
          _buildStatCard(
            context,
            icon: _soundModeIcon(session.soundMode),
            label: 'Sound Mode',
            value: _soundModeLabel(session.soundMode),
          ),
          if (session.notes != null && session.notes!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.notes,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Notes',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(session.notes!),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: () => _continueSession(context, ref),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Continue Session'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Future<void> _deleteSession(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Session?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    ref.read(sessionsProvider.notifier).deleteSession(session.id);
    if (context.mounted) Navigator.of(context).pop();
  }

  Future<void> _continueSession(BuildContext context, WidgetRef ref) async {
    final currentCount = ref.read(counterProvider).count;
    if (currentCount > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Continue Session?'),
          content: Text(
            'This will replace your current count ($currentCount) with ${session.finalCount} from "${session.mantra}".',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    ref.read(counterProvider.notifier).loadSession(session);
    if (context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Widget _buildStatCard(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodySmall),
                Text(value, style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }

  String _formatDateTime(DateTime date) {
    return '${date.day}/${date.month}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  IconData _soundModeIcon(SoundMode mode) {
    return switch (mode) {
      SoundMode.mute => Icons.volume_off,
      SoundMode.sound => Icons.volume_up,
      SoundMode.vibrate => Icons.vibration,
      SoundMode.soundAndVibrate => Icons.speaker_phone,
    };
  }

  String _soundModeLabel(SoundMode mode) {
    return switch (mode) {
      SoundMode.mute => 'Mute',
      SoundMode.sound => 'Sound',
      SoundMode.vibrate => 'Vibrate',
      SoundMode.soundAndVibrate => 'Sound & Vibrate',
    };
  }
}
