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

  /// The phrase the user chanted, when the session was counted by voice.
  ///
  /// Null for tap-only sessions. Kept separate from [mantra], which is the
  /// user's own label for the session and may differ from what they said.
  @HiveField(12)
  final String? phrase;

  /// Counts detected from speech. Null for sessions recorded before voice
  /// counting existed, and for tap-only sessions.
  @HiveField(13)
  final int? voiceCount;

  /// Counts entered by tapping. Null under the same conditions as [voiceCount].
  @HiveField(14)
  final int? manualCount;

  /// Whether this session recorded any voice-counted repetitions.
  bool get isVoiceSession => (voiceCount ?? 0) > 0 || phrase != null;

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
    this.phrase,
    this.voiceCount,
    this.manualCount,
  }) : id = id ?? _uuid.v4();
}
