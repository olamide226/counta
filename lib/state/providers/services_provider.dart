import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/background_voice_service.dart';
import '../../core/services/counter_alert_service.dart';
import '../../core/services/screen_wake_service.dart';
import '../../core/services/tap_feedback_service.dart';
import '../../core/services/notification_service.dart';
import '../../core/services/live_activity_service.dart';
import 'settings_provider.dart';

final tapFeedbackServiceProvider = Provider<TapFeedbackService>(
  (ref) => TapFeedbackService(),
);

final alertServiceProvider = Provider<CounterAlertService>((ref) {
  return CounterAlertService();
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  final service = NotificationService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Holds the screen awake exactly when Settings → Keep Screen On says so.
/// A voice session does not override it: the session survives a screen lock
/// (the audio background mode on iOS, `BackgroundVoiceService` on Android).
/// Read once by `App` so it is live from launch.
final screenWakeServiceProvider = Provider<ScreenWakeService>((ref) {
  final service = ScreenWakeService();
  ref.listen<bool>(
    settingsProvider.select((settings) => settings.keepScreenOn),
    (_, keepOn) => service.setActive(keepOn),
    fireImmediately: true,
  );
  ref.onDispose(() => service.dispose());
  return service;
});

final backgroundVoiceServiceProvider = Provider<BackgroundVoiceService>(
  (ref) => BackgroundVoiceService(),
);

final liveActivityServiceProvider = Provider<LiveActivityService>((ref) {
  final service = LiveActivityService();
  service.init();
  return service;
});
