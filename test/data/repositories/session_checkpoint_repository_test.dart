import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:counta/data/repositories/session_checkpoint_repository.dart';
import 'package:counta/domain/models/count_session.dart';
import 'package:counta/domain/models/enums.dart';

CountSession sample({
  String id = 'cp-1',
  int count = 42,
  bool completed = false,
  DateTime? endedAt,
}) {
  return CountSession(
    id: id,
    mantra: 'om mani padme hum',
    startedAt: DateTime(2026, 3, 1, 9),
    endedAt: endedAt ?? DateTime(2026, 3, 1, 9, 30),
    finalCount: count,
    threshold: 108,
    soundMode: SoundMode.vibrate,
    themeModeChoice: ThemeModeChoice.dark,
    themeId: AppThemeId.forest,
    phrase: 'om mani padme hum',
    voiceCount: 40,
    manualCount: 2,
    completed: completed,
    creditsConsumed: 3,
  );
}

void main() {
  late Directory dir;
  late Box<CountSession> checkpointBox;

  setUpAll(() {
    Hive.registerAdapter(SoundModeAdapter());
    Hive.registerAdapter(ThemeModeChoiceAdapter());
    Hive.registerAdapter(AppThemeIdAdapter());
    Hive.registerAdapter(CountSessionAdapter());
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('counta_hive_');
    Hive.init(dir.path);
    checkpointBox = await Hive.openBox<CountSession>('checkpoint_test');
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  group('SessionCheckpointRepository', () {
    test('reads null when nothing has been checkpointed', () {
      final repo = SessionCheckpointRepository(checkpointBox);
      expect(repo.read(), isNull);
    });

    test('round-trips every persisted field', () async {
      final repo = SessionCheckpointRepository(checkpointBox);
      await repo.write(sample());

      final read = repo.read();
      expect(read, isNotNull);
      expect(read!.id, 'cp-1');
      expect(read.mantra, 'om mani padme hum');
      expect(read.startedAt, DateTime(2026, 3, 1, 9));
      expect(read.endedAt, DateTime(2026, 3, 1, 9, 30));
      expect(read.finalCount, 42);
      expect(read.threshold, 108);
      expect(read.phrase, 'om mani padme hum');
      expect(read.voiceCount, 40);
      expect(read.manualCount, 2);
      expect(read.completed, isFalse);
      expect(read.creditsConsumed, 3);
    });

    test(
      'holds a single checkpoint; later writes replace earlier ones',
      () async {
        final repo = SessionCheckpointRepository(checkpointBox);
        await repo.write(sample(count: 1));
        await repo.write(sample(count: 2));
        await repo.write(sample(id: 'cp-2', count: 3));

        expect(checkpointBox.length, 1);
        expect(repo.read()?.id, 'cp-2');
        expect(repo.read()?.finalCount, 3);
      },
    );

    test('clear removes the checkpoint', () async {
      final repo = SessionCheckpointRepository(checkpointBox);
      await repo.write(sample());
      await repo.clear();

      expect(repo.read(), isNull);
      expect(checkpointBox.isEmpty, isTrue);
    });

    test('take returns the checkpoint and empties the store', () async {
      final repo = SessionCheckpointRepository(checkpointBox);
      await repo.write(sample());

      final taken = await repo.take();

      expect(taken?.id, 'cp-1');
      expect(taken?.finalCount, 42);
      // The whole point: recovery owns it now, so a session starting in the
      // same launch cannot overwrite what the crash left behind.
      expect(repo.read(), isNull);
      expect(checkpointBox.isEmpty, isTrue);
    });

    test('take on an empty store returns null without throwing', () async {
      final repo = SessionCheckpointRepository(checkpointBox);
      expect(await repo.take(), isNull);
      expect(repo.read(), isNull);
    });
  });
}
