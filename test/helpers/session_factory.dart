import 'package:counta/domain/models/count_session.dart';
import 'package:counta/domain/models/enums.dart';

/// A [CountSession] with sane defaults, so a test names only the fields it is
/// actually about.
CountSession testSession({
  String id = 'cp-1',
  String mantra = 'om mani padme hum',
  DateTime? startedAt,
  DateTime? endedAt,
  int finalCount = 42,
  int? threshold = 108,
  int? repeatInterval,
  SoundMode soundMode = SoundMode.vibrate,
  ThemeModeChoice themeModeChoice = ThemeModeChoice.dark,
  AppThemeId themeId = AppThemeId.forest,
  String? notes,
  String? phrase = 'om mani padme hum',
  int? voiceCount = 40,
  int? manualCount = 2,
  bool completed = false,
  int? creditsConsumed = 3,
}) {
  return CountSession(
    id: id,
    mantra: mantra,
    startedAt: startedAt ?? DateTime(2026, 3, 1, 9),
    endedAt: endedAt ?? DateTime(2026, 3, 1, 9, 30),
    finalCount: finalCount,
    threshold: threshold,
    repeatInterval: repeatInterval,
    soundMode: soundMode,
    themeModeChoice: themeModeChoice,
    themeId: themeId,
    notes: notes,
    phrase: phrase,
    voiceCount: voiceCount,
    manualCount: manualCount,
    completed: completed,
    creditsConsumed: creditsConsumed,
  );
}
