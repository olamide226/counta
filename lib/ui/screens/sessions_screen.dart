import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/date_format.dart';
import '../../state/providers/sessions_provider.dart';
import 'session_detail_screen.dart';

class SessionsScreen extends ConsumerWidget {
  const SessionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(sessionsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Sessions'), centerTitle: true),
      body: sessions.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'No sessions yet',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Save a session to see it here',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: sessions.length,
              itemBuilder: (context, index) {
                final session = sessions[index];
                // Built once: the subtitle and the three-line flag have to
                // agree, and deriving both from the same list is what makes
                // that true by construction rather than by matching two
                // copies of the same condition.
                final lines = [
                  if (session.phrase != null &&
                      session.phrase != session.mantra)
                    '“${session.phrase}”',
                  '${session.finalCount} counts • '
                      '${session.endedAt.asSessionTimestamp}',
                  if (!session.completed) 'Recovered after interruption',
                ];
                return Dismissible(
                  key: Key(session.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Colors.red,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  confirmDismiss: (_) => _confirmDelete(context),
                  onDismissed: (_) {
                    ref
                        .read(sessionsProvider.notifier)
                        .deleteSession(session.id);
                  },
                  child: ListTile(
                    leading: session.isVoiceSession
                        ? Icon(
                            Icons.graphic_eq_rounded,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : const Icon(Icons.touch_app_outlined),
                    title: Text(session.mantra),
                    subtitle: Text(lines.join('\n')),
                    isThreeLine: lines.length > 2,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SessionDetailScreen(session: session),
                        ),
                      );
                    },
                    onLongPress: () async {
                      final confirmed = await _confirmDelete(context);
                      if (confirmed) {
                        ref
                            .read(sessionsProvider.notifier)
                            .deleteSession(session.id);
                      }
                    },
                  ),
                );
              },
            ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final result = await showDialog<bool>(
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
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}
