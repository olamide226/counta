import '../models/count_session.dart';

/// One backed-up session as the server holds it.
class BackedUpSession {
  const BackedUpSession(this.id, this.session);

  final String id;

  /// Null when the session was deleted on some phone.
  final CountSession? session;
}

/// Where a signed-in account's saved sessions are backed up.
///
/// Always the account signed in now: the adapter sends the user's own
/// credentials, and the server only ever shows a user their own rows.
abstract interface class SessionBackup {
  /// Every session the account has backed up, deletions included.
  Future<List<BackedUpSession>> fetchAll();

  /// Backs up [sessions], replacing any earlier copy (or deletion) of each.
  Future<void> save(List<CountSession> sessions);

  /// Marks [ids] deleted, so every phone signed in to the account drops them.
  Future<void> delete(List<String> ids);
}
