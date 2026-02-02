import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class CounterAlertService {
  // Check if platform supports haptic feedback
  bool get _supportsHaptics {
    if (kIsWeb) return false;
    return Platform.isIOS || Platform.isAndroid;
  }

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
    if (_supportsHaptics) {
      await HapticFeedback.mediumImpact();
      await Future.delayed(const Duration(milliseconds: 100));
      await HapticFeedback.mediumImpact();
    }
    // Desktop/web: visual feedback handled by UI
  }
}
