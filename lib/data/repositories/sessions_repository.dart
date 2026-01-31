import 'package:hive/hive.dart';

import '../../domain/models/count_session.dart';
import '../hive/hive_init.dart';

class SessionsRepository {
  final Box<CountSession> _box;

  SessionsRepository(this._box);

  List<CountSession> getAllSessions() {
    final sessions = _box.values.toList();
    sessions.sort((a, b) => b.endedAt.compareTo(a.endedAt));
    return sessions;
  }

  CountSession? getSession(String id) {
    return _box.get(id);
  }

  Future<void> saveSession(CountSession session) async {
    await _box.put(session.id, session);
  }

  Future<void> deleteSession(String id) async {
    await _box.delete(id);
  }

  Future<void> deleteAllSessions() async {
    await _box.clear();
  }
}

SessionsRepository createSessionsRepository() {
  return SessionsRepository(getSessionsBox());
}
