import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/count_session.dart';
import 'hive_providers.dart';

final sessionsProvider =
    StateNotifierProvider<SessionsNotifier, List<CountSession>>((ref) {
      final repo = ref.watch(sessionsRepositoryProvider);
      return SessionsNotifier(repo);
    });

class SessionsNotifier extends StateNotifier<List<CountSession>> {
  final dynamic _repository;

  SessionsNotifier(this._repository) : super(_repository.getAllSessions());

  Future<void> saveSession(CountSession session) async {
    await _repository.saveSession(session);
    state = _repository.getAllSessions();
  }

  Future<void> deleteSession(String id) async {
    await _repository.deleteSession(id);
    state = _repository.getAllSessions();
  }

  void refresh() {
    state = _repository.getAllSessions();
  }
}
