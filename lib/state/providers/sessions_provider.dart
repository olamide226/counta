import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/count_session.dart';
import 'hive_providers.dart';
import 'session_checkpointer.dart';
import 'session_sync.dart';

final sessionsProvider =
    StateNotifierProvider<SessionsNotifier, List<CountSession>>((ref) {
      final repo = ref.watch(sessionsRepositoryProvider);
      return SessionsNotifier(
        repo,
        // Read lazily, inside the callback: touching the checkpointer while
        // building this provider would attach it before the startup step has
        // taken the previous run's checkpoint out of the store.
        onSaved: () => ref.read(sessionCheckpointerProvider).clear(),
        // Read lazily too: the sync reads this provider back when it restores.
        onBackup: (session) => ref.read(sessionSyncProvider)?.saved(session),
        onDeleted: (id) => ref.read(sessionSyncProvider)?.deleted(id),
      );
    });

class SessionsNotifier extends StateNotifier<List<CountSession>> {
  final dynamic _repository;
  final Future<void> Function()? _onSaved;
  final void Function(CountSession)? _onBackup;
  final void Function(String)? _onDeleted;

  SessionsNotifier(
    this._repository, {
    Future<void> Function()? onSaved,
    void Function(CountSession)? onBackup,
    void Function(String)? onDeleted,
  }) : _onSaved = onSaved,
       _onBackup = onBackup,
       _onDeleted = onDeleted,
       super(_repository.getAllSessions());

  Future<void> saveSession(CountSession session) async {
    await _repository.saveSession(session);
    state = _repository.getAllSessions();

    // The counts are in history now, so a checkpoint holding the same ones
    // would offer them back on the next launch. Retiring it here covers every
    // save path at once — the save sheet and recovery's "save to history" each
    // used to have to remember to clear, and one of them forgetting is a
    // duplicate session the user has to delete by hand.
    await _onSaved?.call();
    _onBackup?.call(session);
  }

  Future<void> deleteSession(String id) async {
    await _repository.deleteSession(id);
    state = _repository.getAllSessions();
    _onDeleted?.call(id);
  }

  void refresh() {
    state = _repository.getAllSessions();
  }
}
