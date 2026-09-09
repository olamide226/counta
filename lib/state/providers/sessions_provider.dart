import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/count_session.dart';
import 'hive_providers.dart';
import 'session_checkpointer.dart';

final sessionsProvider =
    StateNotifierProvider<SessionsNotifier, List<CountSession>>((ref) {
      final repo = ref.watch(sessionsRepositoryProvider);
      return SessionsNotifier(
        repo,
        // Read lazily, inside the callback: touching the checkpointer while
        // building this provider would attach it before the startup step has
        // taken the previous run's checkpoint out of the store.
        onSaved: () => ref.read(sessionCheckpointerProvider).clear(),
      );
    });

class SessionsNotifier extends StateNotifier<List<CountSession>> {
  final dynamic _repository;
  final Future<void> Function()? _onSaved;

  SessionsNotifier(this._repository, {Future<void> Function()? onSaved})
    : _onSaved = onSaved,
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
  }

  Future<void> deleteSession(String id) async {
    await _repository.deleteSession(id);
    state = _repository.getAllSessions();
  }

  void refresh() {
    state = _repository.getAllSessions();
  }
}
