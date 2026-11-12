import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/sync/supabase_session_backup.dart';
import '../../data/repositories/session_sync_queue.dart';
import '../../domain/account/account.dart';
import '../../domain/models/count_session.dart';
import '../../domain/sync/session_backup.dart';
import 'account_provider.dart';
import 'hive_providers.dart';
import 'sessions_provider.dart';

/// Backs up a signed-in account's saved sessions, and brings them back on
/// another phone.
///
/// The phone stays the source of truth and works offline exactly as before;
/// this only copies. Sessions are never edited after saving, so two phones
/// can't disagree about one — a session is either there or deleted, and the
/// merge is a union that honours deletions. Guests are not backed up: their
/// history is uploaded the moment they sign in.
class SessionSync {
  SessionSync({
    required this.backup,
    required this.queue,
    required this.local,
    required this.store,
    required this.remove,
    required this.changed,
  });

  final SessionBackup backup;
  final SessionSyncQueue queue;

  /// The phone's saved sessions, read fresh.
  final List<CountSession> Function() local;

  /// Writes a session restored from the backup, without sending it back.
  final Future<void> Function(CountSession) store;

  /// Drops a session another phone deleted, without sending it back.
  final Future<void> Function(String) remove;

  /// The saved list changed underneath the screens showing it.
  final void Function() changed;

  bool _signedIn = false;

  /// Every network step runs after the one before, so a save during a restore
  /// cannot be sent twice or overtaken.
  Future<void> _tail = Future.value();

  /// The account signed in now; null for a guest.
  void accountChanged({required bool signedIn}) {
    final signedOut = _signedIn && !signedIn;
    _signedIn = signedIn;
    if (signedIn) {
      _then(_merge);
    } else if (signedOut) {
      // What was pending belonged to the account that left. If one signs in
      // again, the merge finds anything still missing. Only on a real
      // sign-out: at launch the app reads as a guest until the session is up,
      // and clearing then would lose a deletion made offline.
      _then(queue.clear);
    }
  }

  void saved(CountSession session) {
    if (!_signedIn) return;
    _then(() async {
      await queue.markSaved([session.id]);
      await _send();
    });
  }

  void deleted(String id) {
    if (!_signedIn) return;
    _then(() async {
      await queue.markDeleted(id);
      await _send();
    });
  }

  /// Runs once nothing is in flight. For tests.
  @visibleForTesting
  Future<void> get idle => _tail;

  void _then(Future<void> Function() step) {
    _tail = _tail.then((_) => step()).catchError((Object error) {
      // Offline, or the server refused. What was pending stays queued for the
      // next sync; the phone's own copy is untouched either way.
      debugPrint('Session backup: $error');
    });
  }

  Future<void> _merge() async {
    if (!_signedIn) return;
    final backedUp = await backup.fetchAll();
    final mine = {for (final s in local()) s.id: s};
    final known = <String>{};
    var restored = false;

    for (final BackedUpSession(:id, :session) in backedUp) {
      known.add(id);
      if (session == null) {
        // Deleted on another phone — unless this one saved it again since.
        if (mine.containsKey(id) && !queue.isSavePending(id)) {
          await remove(id);
          restored = true;
        }
      } else if (!mine.containsKey(id) && !queue.isDeletePending(id)) {
        await store(session);
        restored = true;
      }
    }
    if (restored) changed();

    await queue.markSaved(mine.keys.where((id) => !known.contains(id)));
    await _send();
  }

  Future<void> _send() async {
    if (!_signedIn) return;
    final saves = queue.saves.toList();
    if (saves.isNotEmpty) {
      final byId = {for (final s in local()) s.id: s};
      await backup.save([
        for (final id in saves)
          if (byId[id] case final session?) session,
      ]);
      await queue.sent(saves, deleted: false);
    }
    final deletes = queue.deletes.toList();
    if (deletes.isNotEmpty) {
      await backup.delete(deletes);
      await queue.sent(deletes, deleted: true);
    }
  }
}

final sessionSyncQueueProvider = Provider<SessionSyncQueue>(
  (ref) => createSessionSyncQueue(),
);

/// Null in a build with no backend, where there is nowhere to back up to.
final Provider<SessionSync?> sessionSyncProvider = Provider<SessionSync?>((
  ref,
) {
  if (!ref.watch(accountProvider.select((a) => a.available))) return null;

  final repository = ref.watch(sessionsRepositoryProvider);
  final sync = SessionSync(
    backup: SupabaseSessionBackup(Supabase.instance.client),
    queue: ref.watch(sessionSyncQueueProvider),
    local: repository.getAllSessions,
    store: repository.saveSession,
    remove: repository.deleteSession,
    changed: () => ref.read(sessionsProvider.notifier).refresh(),
  );

  // Each account the phone runs as — at launch once the session is up, after
  // a sign-in, after a sign-out — gets one merge.
  ref.listen(
    accountProvider.select((a) => a.status),
    (_, status) => sync.accountChanged(signedIn: status is SignedInAccount),
    fireImmediately: true,
  );
  return sync;
});
