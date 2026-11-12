import 'package:hive/hive.dart';

import '../hive/hive_init.dart';

/// Changes to saved sessions not yet backed up: session id → what to send.
///
/// Kept on disk, so a session saved offline (or just before the app was
/// killed) is still sent the next time the account syncs. Each id holds only
/// its latest change: a save then a delete is a delete.
class SessionSyncQueue {
  SessionSyncQueue(this._box);

  final Box _box;

  static const _save = 'save';
  static const _delete = 'delete';

  Iterable<String> get saves => _ids(_save);
  Iterable<String> get deletes => _ids(_delete);

  bool isDeletePending(String id) => _box.get(id) == _delete;
  bool isSavePending(String id) => _box.get(id) == _save;

  Future<void> markSaved(Iterable<String> ids) =>
      _box.putAll({for (final id in ids) id: _save});

  Future<void> markDeleted(String id) => _box.put(id, _delete);

  /// Drops [ids] once sent — unless a newer change for one arrived meanwhile.
  Future<void> sent(Iterable<String> ids, {required bool deleted}) =>
      _box.deleteAll([
        for (final id in ids)
          if (_box.get(id) == (deleted ? _delete : _save)) id,
      ]);

  Future<void> clear() => _box.clear();

  Iterable<String> _ids(String op) =>
      _box.keys.whereType<String>().where((id) => _box.get(id) == op);
}

SessionSyncQueue createSessionSyncQueue() =>
    SessionSyncQueue(getSessionSyncBox());
