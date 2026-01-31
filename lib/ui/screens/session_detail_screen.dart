import 'package:flutter/material.dart';

import '../../domain/models/count_session.dart';
import '../../domain/models/enums.dart';

class SessionDetailScreen extends StatelessWidget {
  const SessionDetailScreen({super.key, required this.session});

  final CountSession session;

  @override
  Widget build(BuildContext context) {
    final duration = session.endedAt.difference(session.startedAt);

    return Scaffold(
      appBar: AppBar(title: Text(session.mantra), centerTitle: true),
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
        ],
      ),
    );
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
