import 'count_session.dart';
import 'enums.dart';

/// A saved session as JSON, for the account backup.
///
/// Enums are written by name and dates as UTC ISO-8601, so a backup written by
/// one build reads back on any other. Unknown or missing fields read back as
/// their defaults rather than failing: a newer build's backup must still
/// restore on an older one.
Map<String, Object?> sessionToJson(CountSession s) => {
  'mantra': s.mantra,
  'startedAt': s.startedAt.toUtc().toIso8601String(),
  'endedAt': s.endedAt.toUtc().toIso8601String(),
  'finalCount': s.finalCount,
  'threshold': s.threshold,
  'repeatInterval': s.repeatInterval,
  'soundMode': s.soundMode.name,
  'themeModeChoice': s.themeModeChoice.name,
  'themeId': s.themeId.name,
  'notes': s.notes,
  'deviceLocale': s.deviceLocale,
  'phrase': s.phrase,
  'voiceCount': s.voiceCount,
  'manualCount': s.manualCount,
  'completed': s.completed,
  'creditsConsumed': s.creditsConsumed,
  'phrases': s.phrases,
  'phraseCounts': s.phraseCounts,
};

/// The session [id] from its backed-up [json]. Throws [FormatException] when
/// the essentials (dates, count) are missing.
CountSession sessionFromJson(String id, Map<String, Object?> json) {
  DateTime date(String key) {
    final value = json[key];
    final parsed = value is String ? DateTime.tryParse(value) : null;
    if (parsed == null) throw FormatException('session $id: bad $key');
    return parsed.toLocal();
  }

  int? integer(String key) => switch (json[key]) {
    final int v => v,
    final num v => v.toInt(),
    _ => null,
  };

  T named<T extends Enum>(List<T> values, String key, T fallback) {
    final name = json[key];
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }

  final finalCount = integer('finalCount');
  if (finalCount == null) throw FormatException('session $id: no count');
  final phrases = json['phrases'];
  final phraseCounts = json['phraseCounts'];

  return CountSession(
    id: id,
    mantra: json['mantra'] as String? ?? '',
    startedAt: date('startedAt'),
    endedAt: date('endedAt'),
    finalCount: finalCount,
    threshold: integer('threshold'),
    repeatInterval: integer('repeatInterval'),
    soundMode: named(SoundMode.values, 'soundMode', SoundMode.sound),
    themeModeChoice: named(
      ThemeModeChoice.values,
      'themeModeChoice',
      ThemeModeChoice.system,
    ),
    themeId: named(AppThemeId.values, 'themeId', AppThemeId.ocean),
    notes: json['notes'] as String?,
    deviceLocale: json['deviceLocale'] as String?,
    phrase: json['phrase'] as String?,
    voiceCount: integer('voiceCount'),
    manualCount: integer('manualCount'),
    completed: json['completed'] as bool? ?? true,
    creditsConsumed: integer('creditsConsumed'),
    phrases: phrases is List ? phrases.whereType<String>().toList() : null,
    phraseCounts: phraseCounts is Map
        ? {
            for (final MapEntry(:key, :value) in phraseCounts.entries)
              if (key is String && value is num) key: value.toInt(),
          }
        : null,
  );
}
