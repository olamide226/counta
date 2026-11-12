import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../domain/models/count_session.dart';
import '../../../domain/models/session_json.dart';
import '../../../domain/sync/session_backup.dart';

/// [SessionBackup] on the `counta.sessions` table, through PostgREST with the
/// signed-in user's own JWT. Row-level security is what keeps each account to
/// its own rows; nothing here filters by user.
class SupabaseSessionBackup implements SessionBackup {
  SupabaseSessionBackup(this._client);

  final SupabaseClient _client;

  /// PostgREST answers at most this many rows per request.
  static const _page = 1000;

  SupabaseQueryBuilder get _table => _client.schema('counta').from('sessions');

  String get _userId {
    final id = _client.auth.currentUser?.id;
    if (id == null) throw StateError('No signed-in user to back up for.');
    return id;
  }

  @override
  Future<List<BackedUpSession>> fetchAll() async {
    final all = <BackedUpSession>[];
    for (var from = 0; ; from += _page) {
      final rows = await _table
          .select('id, data')
          .order('id')
          .range(from, from + _page - 1);
      for (final row in rows) {
        final id = row['id'] as String;
        final data = row['data'];
        if (data is! Map) {
          all.add(BackedUpSession(id, null));
          continue;
        }
        try {
          all.add(
            BackedUpSession(
              id,
              sessionFromJson(id, Map<String, Object?>.from(data)),
            ),
          );
        } on FormatException catch (error) {
          // One unreadable row must not cost the rest of the history.
          debugPrint('Skipping backed-up session: $error');
        }
      }
      if (rows.length < _page) return all;
    }
  }

  @override
  Future<void> save(List<CountSession> sessions) async {
    if (sessions.isEmpty) return;
    final userId = _userId;
    final now = DateTime.now().toUtc().toIso8601String();
    await _table.upsert([
      for (final session in sessions)
        {
          'user_id': userId,
          'id': session.id,
          'data': sessionToJson(session),
          'deleted_at': null,
          'updated_at': now,
        },
    ], onConflict: 'user_id,id');
  }

  @override
  Future<void> delete(List<String> ids) async {
    if (ids.isEmpty) return;
    final userId = _userId;
    final now = DateTime.now().toUtc().toIso8601String();
    await _table.upsert([
      for (final id in ids)
        {
          'user_id': userId,
          'id': id,
          'data': null,
          'deleted_at': now,
          'updated_at': now,
        },
    ], onConflict: 'user_id,id');
  }
}
