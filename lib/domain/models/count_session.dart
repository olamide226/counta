import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import 'enums.dart';

part 'count_session.g.dart';

const _uuid = Uuid();

@HiveType(typeId: 1)
class CountSession {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String mantra;

  @HiveField(2)
  final DateTime startedAt;

  @HiveField(3)
  final DateTime endedAt;

  @HiveField(4)
  final int finalCount;

  @HiveField(5)
  final int? threshold;

  @HiveField(6)
  final int? repeatInterval;

  @HiveField(7)
  final SoundMode soundMode;

  @HiveField(8)
  final ThemeModeChoice themeModeChoice;

  @HiveField(9)
  final AppThemeId themeId;

  @HiveField(10)
  final String? notes;

  @HiveField(11)
  final String? deviceLocale;

  CountSession({
    String? id,
    required this.mantra,
    required this.startedAt,
    required this.endedAt,
    required this.finalCount,
    this.threshold,
    this.repeatInterval,
    required this.soundMode,
    required this.themeModeChoice,
    required this.themeId,
    this.notes,
    this.deviceLocale,
  }) : id = id ?? _uuid.v4();
}
