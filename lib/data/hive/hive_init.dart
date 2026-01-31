import 'package:hive_flutter/hive_flutter.dart';

import '../../domain/models/app_settings.dart';
import '../../domain/models/count_session.dart';
import '../../domain/models/enums.dart';

const String settingsBoxName = 'settings';
const String sessionsBoxName = 'sessions';

Future<void> initHive() async {
  await Hive.initFlutter();

  // Register adapters
  Hive.registerAdapter(SoundModeAdapter());
  Hive.registerAdapter(ThemeModeChoiceAdapter());
  Hive.registerAdapter(AppThemeIdAdapter());
  Hive.registerAdapter(AppSettingsAdapter());
  Hive.registerAdapter(CountSessionAdapter());

  // Open boxes
  await Hive.openBox<AppSettings>(settingsBoxName);
  await Hive.openBox<CountSession>(sessionsBoxName);
}

Box<AppSettings> getSettingsBox() => Hive.box<AppSettings>(settingsBoxName);
Box<CountSession> getSessionsBox() => Hive.box<CountSession>(sessionsBoxName);
