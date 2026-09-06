import 'package:hive/hive.dart';

import 'enums.dart';

part 'app_settings.g.dart';

@HiveType(typeId: 0)
class AppSettings {
  @HiveField(0)
  final ThemeModeChoice themeModeChoice;

  @HiveField(1)
  final AppThemeId themeId;

  @HiveField(2)
  final SoundMode soundMode;

  @HiveField(3)
  final int? defaultThreshold;

  @HiveField(4)
  final int? defaultRepeatInterval;

  @HiveField(5)
  final double tapZoneRatio;

  @HiveField(6)
  final bool confirmReset;

  @HiveField(7)
  final bool keepScreenOn;

  /// Whether the user has been told that voice sessions stream audio to a
  /// third-party speech recognition provider. Defaults to false so settings
  /// documents written before this field existed still load and show the
  /// disclosure once.
  @HiveField(8, defaultValue: false)
  final bool voiceDisclosureSeen;

  const AppSettings({
    required this.themeModeChoice,
    required this.themeId,
    required this.soundMode,
    this.defaultThreshold,
    this.defaultRepeatInterval,
    required this.tapZoneRatio,
    required this.confirmReset,
    required this.keepScreenOn,
    this.voiceDisclosureSeen = false,
  });

  factory AppSettings.defaults() {
    return const AppSettings(
      themeModeChoice: ThemeModeChoice.system,
      themeId: AppThemeId.ocean,
      soundMode: SoundMode.vibrate,
      defaultThreshold: 100,
      defaultRepeatInterval: 100,
      tapZoneRatio: 0.75,
      confirmReset: true,
      keepScreenOn: false,
      voiceDisclosureSeen: false,
    );
  }

  AppSettings copyWith({
    ThemeModeChoice? themeModeChoice,
    AppThemeId? themeId,
    SoundMode? soundMode,
    int? defaultThreshold,
    int? defaultRepeatInterval,
    double? tapZoneRatio,
    bool? confirmReset,
    bool? keepScreenOn,
    bool? voiceDisclosureSeen,
  }) {
    return AppSettings(
      themeModeChoice: themeModeChoice ?? this.themeModeChoice,
      themeId: themeId ?? this.themeId,
      soundMode: soundMode ?? this.soundMode,
      defaultThreshold: defaultThreshold ?? this.defaultThreshold,
      defaultRepeatInterval:
          defaultRepeatInterval ?? this.defaultRepeatInterval,
      tapZoneRatio: tapZoneRatio ?? this.tapZoneRatio,
      confirmReset: confirmReset ?? this.confirmReset,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      voiceDisclosureSeen: voiceDisclosureSeen ?? this.voiceDisclosureSeen,
    );
  }
}
