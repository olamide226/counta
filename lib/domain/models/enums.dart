import 'package:hive/hive.dart';

part 'enums.g.dart';

@HiveType(typeId: 10)
enum SoundMode {
  @HiveField(0)
  mute,
  @HiveField(1)
  sound,
  @HiveField(2)
  vibrate,
  @HiveField(3)
  soundAndVibrate,
}

@HiveType(typeId: 11)
enum ThemeModeChoice {
  @HiveField(0)
  system,
  @HiveField(1)
  light,
  @HiveField(2)
  dark,
}

@HiveType(typeId: 12)
enum AppThemeId {
  @HiveField(0)
  ocean,
  @HiveField(1)
  forest,
  @HiveField(2)
  sunset,
  @HiveField(3)
  mono,
  @HiveField(4)
  lavender,
}
