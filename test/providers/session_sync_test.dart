import 'package:counta/data/repositories/session_sync_queue.dart';
import 'package:counta/domain/models/count_session.dart';
import 'package:counta/domain/models/enums.dart';
import 'package:counta/domain/models/session_json.dart';
import 'package:counta/domain/sync/session_backup.dart';
import 'package:counta/state/providers/session_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import '../helpers/session_factory.dart';
import '../helpers/temp_hive.dart';

/// The server side, in memory: id → session, or null once deleted.
class _FakeBackup implements SessionBackup {
  final rows = <String, CountSession?>{};
  bool offline = false;
  int fetches = 0;

  @override
  Future<List<BackedUpSession>> fetchAll() async {
    if (offline) throw Exception('offline');
    fetches++;
    return [
      for (final MapEntry(:key, :value) in rows.entries)
        BackedUpSession(key, value),
    ];
  }

  @override
  Future<void> save(List<CountSession> sessions) async {
    if (offline) throw Exception('offline');
    for (final s in sessions) {
      rows[s.id] = s;
    }
  }

  @override
  Future<void> delete(List<String> ids) async {
    if (offline) throw Exception('offline');
    for (final id in ids) {
      rows[id] = null;
    }
  }
}

void main() {
  group('session JSON', () {
    test('round-trips every field', () {
      final session = testSession(notes: 'evening', completed: true).copyWith(
        phrases: ['I am grateful', 'thank you'],
        phraseCounts: {'I am grateful': 30, 'thank you': 10},
        deviceLocale: 'en_GB',
        themeModeChoice: ThemeModeChoice.light,
      );

      final back = sessionFromJson(session.id, sessionToJson(session));

      expect(sessionToJson(back), sessionToJson(session));
      expect(back.startedAt, session.startedAt);
      expect(back.phraseCounts, session.phraseCounts);
    });

    test('unknown enum names and missing extras fall back to defaults', () {
      final json = sessionToJson(testSession())
        ..['soundMode'] = 'from-the-future'
        ..remove('phrases')
        ..remove('completed');

      final back = sessionFromJson('x', json);

      expect(back.soundMode, SoundMode.sound);
      expect(back.phrases, isNull);
      expect(back.completed, isTrue);
    });

    test('a row missing its dates is refused, not invented', () {
      final json = sessionToJson(testSession())..remove('startedAt');
      expect(() => sessionFromJson('x', json), throwsFormatException);
    });
  });

  group('SessionSync', () {
    late _FakeBackup backup;
    late Map<String, CountSession> phone;
    late SessionSync sync;
    late int changes;
    late Box queueBox;

    SessionSync newSync() => SessionSync(
      backup: backup,
      queue: SessionSyncQueue(queueBox),
      local: () => phone.values.toList(),
      store: (s) async => phone[s.id] = s,
      remove: (id) async => phone.remove(id),
      changed: () => changes++,
    );

    Future<void> run(Future<void> Function() body) => withTempHive(() async {
      backup = _FakeBackup();
      phone = {};
      changes = 0;
      queueBox = await Hive.openBox('session_sync_test');
      sync = newSync();
      await body();
    });

    test(
      'a guest backs nothing up',
      () => run(() async {
        sync.accountChanged(signedIn: false);
        phone['a'] = testSession(id: 'a');
        sync.saved(phone['a']!);
        await sync.idle;

        expect(backup.rows, isEmpty);
        expect(backup.fetches, 0);
      }),
    );

    test(
      'signing in uploads the history the phone already has',
      () => run(() async {
        phone['a'] = testSession(id: 'a');
        phone['b'] = testSession(id: 'b');

        sync.accountChanged(signedIn: true);
        await sync.idle;

        expect(backup.rows.keys, unorderedEquals(['a', 'b']));
        expect(changes, 0);
      }),
    );

    test(
      'a new phone gets the account history back, without duplicates',
      () => run(() async {
        backup.rows['a'] = testSession(id: 'a');
        backup.rows['gone'] = null;
        phone['b'] = testSession(id: 'b');

        sync.accountChanged(signedIn: true);
        await sync.idle;

        expect(phone.keys, unorderedEquals(['a', 'b']));
        expect(backup.rows.keys, unorderedEquals(['a', 'b', 'gone']));
        expect(backup.rows['gone'], isNull);
        expect(changes, 1);
      }),
    );

    test(
      'a session deleted on another phone is deleted here too',
      () => run(() async {
        phone['a'] = testSession(id: 'a');
        backup.rows['a'] = null;

        sync.accountChanged(signedIn: true);
        await sync.idle;

        expect(phone, isEmpty);
        expect(changes, 1);
      }),
    );

    test(
      'saves and deletes are sent as they happen',
      () => run(() async {
        sync.accountChanged(signedIn: true);
        await sync.idle;

        phone['a'] = testSession(id: 'a');
        sync.saved(phone['a']!);
        await sync.idle;
        expect(backup.rows['a'], isNotNull);

        phone.remove('a');
        sync.deleted('a');
        await sync.idle;
        expect(backup.rows.containsKey('a'), isTrue);
        expect(backup.rows['a'], isNull);
      }),
    );

    test(
      'an offline delete is sent later and not undone by the merge',
      () => run(() async {
        phone['a'] = testSession(id: 'a');
        sync.accountChanged(signedIn: true);
        await sync.idle;

        backup.offline = true;
        phone.remove('a');
        sync.deleted('a');
        await sync.idle;
        expect(backup.rows['a'], isNotNull);

        // Next launch: a fresh sync, which reads as a guest until the
        // session is up, then signed in.
        backup.offline = false;
        sync = newSync();
        sync.accountChanged(signedIn: false);
        sync.accountChanged(signedIn: true);
        await sync.idle;

        expect(phone, isEmpty);
        expect(backup.rows['a'], isNull);
      }),
    );

    test(
      'an offline save is sent at the next sync',
      () => run(() async {
        sync.accountChanged(signedIn: true);
        await sync.idle;

        backup.offline = true;
        phone['a'] = testSession(id: 'a');
        sync.saved(phone['a']!);
        await sync.idle;
        expect(backup.rows, isEmpty);

        backup.offline = false;
        sync.accountChanged(signedIn: true);
        await sync.idle;
        expect(backup.rows['a'], isNotNull);
      }),
    );
  });
}
