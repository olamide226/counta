import 'package:counta/core/services/notification_service.dart';
import 'package:counta/core/services/tap_feedback_service.dart';
import 'package:counta/domain/models/app_settings.dart';
import 'package:counta/domain/models/count_session.dart';
import 'package:counta/domain/models/enums.dart';

/// Settings repository backed by nothing, for tests that only need the
/// defaults and must not touch Hive.
class MockSettingsRepository {
  MockSettingsRepository([AppSettings? initial])
    : _settings = initial ?? AppSettings.defaults();

  AppSettings _settings;

  AppSettings getSettings() => _settings;

  Future<void> saveSettings(AppSettings settings) async {
    _settings = settings;
  }
}

/// Sessions repository backed by a map, matching `SessionsRepository`'s
/// newest-first ordering.
class InMemorySessionsRepository {
  final Map<String, CountSession> _rows = {};

  List<CountSession> getAllSessions() {
    final sessions = _rows.values.toList();
    sessions.sort((a, b) => b.endedAt.compareTo(a.endedAt));
    return sessions;
  }

  CountSession? getSession(String id) => _rows[id];

  Future<void> saveSession(CountSession session) async =>
      _rows[session.id] = session;

  Future<void> deleteSession(String id) async => _rows.remove(id);

  Future<void> deleteAllSessions() async => _rows.clear();
}

class MockTapFeedbackService implements TapFeedbackService {
  @override
  Future<void> init() async {}

  @override
  Future<void> playTapFeedback(SoundMode mode) async {}

  @override
  void dispose() {}
}

class MockNotificationService implements NotificationService {
  int cancelAllCalls = 0;

  @override
  Future<void> init() async {}

  @override
  Future<void> showResumeNotification({
    required int currentCount,
    String? sessionInfo,
  }) async {}

  @override
  Future<void> showVoiceSessionNotification({
    required int currentCount,
    required String phrase,
  }) async {}

  @override
  Future<void> cancelVoiceSessionNotification() async {}

  @override
  Future<void> cancelAllNotifications() async {
    cancelAllCalls++;
  }

  @override
  void dispose() {}
}
