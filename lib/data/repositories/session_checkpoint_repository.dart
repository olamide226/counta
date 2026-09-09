import 'package:hive/hive.dart';

import '../../domain/models/count_session.dart';
import '../hive/hive_init.dart';

/// Where the in-progress session is checkpointed so an unexpected termination
/// can be recovered on the next launch (requirements 7.2 and 7.3).
///
/// Holds at most one record: the session currently being counted.
abstract interface class SessionCheckpointStore {
  /// The checkpoint left behind by a session that never cleared it, or null.
  ///
  /// Prefer [take] at startup: a checkpoint that is read but left in place can
  /// be overwritten by the very session that is meant to recover it.
  CountSession? read();

  Future<void> write(CountSession checkpoint);

  Future<void> clear();

  /// Reads the checkpoint and removes it in one step, so the caller owns it
  /// outright and no later write can clobber what was recovered.
  Future<CountSession?> take();
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

  @override
  Future<CountSession?> take() async {
    final checkpoint = _box.get(_key);
    if (checkpoint != null) await _box.delete(_key);
    return checkpoint;
  }
}

SessionCheckpointRepository createSessionCheckpointRepository() {
  return SessionCheckpointRepository(getSessionCheckpointBox());
}
