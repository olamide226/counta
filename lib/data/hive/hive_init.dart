import 'package:hive_flutter/hive_flutter.dart';

import '../../domain/models/app_settings.dart';
import '../../domain/models/count_session.dart';
import '../../domain/models/enums.dart';

const String settingsBoxName = 'settings';
const String sessionsBoxName = 'sessions';
const String sessionCheckpointBoxName = 'session_checkpoint';

Future<void> initHive() async {
  await Hive.initFlutter();

  // Register adapters
  Hive.registerAdapter(SoundModeAdapter());
  Hive.registerAdapter(ThemeModeChoiceAdapter());
  Hive.registerAdapter(AppThemeIdAdapter());
  Hive.registerAdapter(AppSettingsAdapter());
  Hive.registerAdapter(CountSessionAdapter());

  // Concurrently: three independent file opens on the startup path, and the
  // app shows a spinner until the last one lands.
  await Future.wait([
    Hive.openBox<AppSettings>(settingsBoxName),
    Hive.openBox<CountSession>(sessionsBoxName),
    Hive.openBox<CountSession>(sessionCheckpointBoxName),
  ]);
}

Box<AppSettings> getSettingsBox() => Hive.box<AppSettings>(settingsBoxName);
Box<CountSession> getSessionsBox() => Hive.box<CountSession>(sessionsBoxName);
Box<CountSession> getSessionCheckpointBox() =>
    Hive.box<CountSession>(sessionCheckpointBoxName);
