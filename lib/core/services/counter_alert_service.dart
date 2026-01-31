import 'package:flutter/services.dart';

class CounterAlertService {
  bool shouldAlert({
    required int previousCount,
    required int newCount,
    required int? threshold,
    required int? repeatInterval,
  }) {
    if (threshold == null || threshold <= 0) return false;

    // Alert at threshold
    if (newCount == threshold) return true;

    // Alert at repeat intervals after threshold
    if (repeatInterval != null && repeatInterval > 0 && newCount > threshold) {
      return (newCount - threshold) % repeatInterval == 0;
    }

    return false;
  }

  Future<void> triggerAlert() async {
    await HapticFeedback.mediumImpact();
    await Future.delayed(const Duration(milliseconds: 100));
    await HapticFeedback.mediumImpact();
  }
}
