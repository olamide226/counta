import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'counter_provider.dart';
import 'services_provider.dart';

class AppLifecycleNotifier extends StateNotifier<AppLifecycleState> {
  final Ref _ref;
  Timer? _notificationTimer;

  AppLifecycleNotifier(this._ref) : super(AppLifecycleState.resumed);

  void handleLifecycleChange(AppLifecycleState newState) {
    state = newState;

    if (newState == AppLifecycleState.paused) {
      _scheduleNotification();
    } else if (newState == AppLifecycleState.resumed) {
      _onAppResumed();
    }
  }

  void _scheduleNotification() {
    final counterState = _ref.read(counterProvider);

    // Only schedule if there's an active counting session
    if (counterState.count == 0) return;

    // Cancel any existing timer
    _notificationTimer?.cancel();

    // Wait 5 minutes before showing notification
    // This prevents annoying notifications for brief app switches
    _notificationTimer = Timer(const Duration(minutes: 5), () {
      final notificationService = _ref.read(notificationServiceProvider);
      final currentCounter = _ref.read(counterProvider);

      // Double-check user hasn't resumed and reset
      if (currentCounter.count == 0) return;

      final sessionDuration = DateTime.now().difference(
        currentCounter.sessionStart,
      );
      final minutes = sessionDuration.inMinutes;
      final sessionInfo = minutes > 0
          ? 'Session duration: ${minutes}m'
          : 'Just started';

      notificationService.showResumeNotification(
        currentCount: currentCounter.count,
        sessionInfo: sessionInfo,
      );
    });
  }

  void _onAppResumed() {
    // Cancel scheduled notification if user returns before timer fires
    _notificationTimer?.cancel();
    _notificationTimer = null;

    final notificationService = _ref.read(notificationServiceProvider);
    // Cancel any shown notifications when app is resumed
    notificationService.cancelAllNotifications();
  }

  @override
  void dispose() {
    _notificationTimer?.cancel();
    super.dispose();
  }
}

final appLifecycleProvider =
    StateNotifierProvider<AppLifecycleNotifier, AppLifecycleState>(
      (ref) => AppLifecycleNotifier(ref),
    );
