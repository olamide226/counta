import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/counter_alert_service.dart';
import '../../core/services/screen_wake_service.dart';
import '../../core/services/tap_feedback_service.dart';
import '../../core/services/notification_service.dart';
import '../../core/services/live_activity_service.dart';
import '../../core/services/counting/microphone_permission_service.dart';

final tapFeedbackServiceProvider = Provider<TapFeedbackService>((ref) {
  final service = TapFeedbackService();
  ref.onDispose(() => service.dispose());
  return service;
});

final alertServiceProvider = Provider<CounterAlertService>((ref) {
  return CounterAlertService();
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  final service = NotificationService();
  ref.onDispose(() => service.dispose());
  return service;
});

final screenWakeServiceProvider = Provider<ScreenWakeService>((ref) {
  final service = ScreenWakeService();
  ref.onDispose(() => service.dispose());
  return service;
});

final liveActivityServiceProvider = Provider<LiveActivityService>((ref) {
  final service = LiveActivityService();
  service.init();
  return service;
});

final microphonePermissionServiceProvider =
    Provider<MicrophonePermissionService>((ref) {
      return MicrophonePermissionService();
    });
