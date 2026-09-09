import 'dart:io';

import 'package:counta/domain/models/app_settings.dart';
import 'package:counta/domain/models/count_session.dart';
import 'package:counta/domain/models/enums.dart';
import 'package:hive/hive.dart';

/// Registers every app adapter, at most once per process.
///
/// Hive throws when a typeId is registered twice and test files share an
/// isolate, so this has to be guarded rather than called blindly.
void registerAppAdapters() {
  if (!Hive.isAdapterRegistered(10)) Hive.registerAdapter(SoundModeAdapter());
  if (!Hive.isAdapterRegistered(11)) {
    Hive.registerAdapter(ThemeModeChoiceAdapter());
  }
  if (!Hive.isAdapterRegistered(12)) Hive.registerAdapter(AppThemeIdAdapter());
  if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(AppSettingsAdapter());
  if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(CountSessionAdapter());
}

/// Runs [body] against a real Hive rooted in a throwaway directory, then closes
/// the boxes and deletes the directory whether or not [body] threw.
Future<T> withTempHive<T>(Future<T> Function() body) async {
  registerAppAdapters();
  final dir = await Directory.systemTemp.createTemp('counta_hive_');
  Hive.init(dir.path);
  try {
    return await body();
  } finally {
    await Hive.close();
    await dir.delete(recursive: true);
  }
}
