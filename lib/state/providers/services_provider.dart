import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/counter_alert_service.dart';
import '../../core/services/tap_feedback_service.dart';
import '../../core/services/notification_service.dart';

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
