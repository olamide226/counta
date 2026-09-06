import 'package:hive/hive.dart';

import '../../domain/models/count_session.dart';
import '../hive/hive_init.dart';

/// Where the in-progress session is checkpointed so an unexpected termination
/// can be recovered on the next launch (requirements 7.2 and 7.3).
///
/// Holds at most one record: the session currently being counted.
abstract interface class SessionCheckpointStore {
  /// The checkpoint left behind by a session that never cleared it, or null.
  CountSession? read();

  Future<void> write(CountSession checkpoint);

  Future<void> clear();
}

class SessionCheckpointRepository implements SessionCheckpointStore {
  static const _key = 'active';

  final Box<CountSession> _box;

  SessionCheckpointRepository(this._box);

  @override
  CountSession? read() => _box.get(_key);

  @override
  Future<void> write(CountSession checkpoint) => _box.put(_key, checkpoint);

  @override
  Future<void> clear() => _box.delete(_key);
}

SessionCheckpointRepository createSessionCheckpointRepository() {
  return SessionCheckpointRepository(getSessionCheckpointBox());
}
