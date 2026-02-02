import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/counter_state.dart';
import 'services_provider.dart';
import 'settings_provider.dart';

final counterProvider = StateNotifierProvider<CounterNotifier, CounterState>(
  (ref) => CounterNotifier(ref),
);

class CounterNotifier extends StateNotifier<CounterState> {
  final Ref _ref;

  CounterNotifier(this._ref)
    : super(CounterState(count: 0, sessionStart: DateTime.now())) {
    _initFromSettings();
  }

  void _initFromSettings() {
    final settings = _ref.read(settingsProvider);
    state = state.copyWith(
      threshold: settings.defaultThreshold,
      repeatInterval: settings.defaultRepeatInterval,
    );
  }

  Future<void> increment() async {
    final previousCount = state.count;
    final newCount = previousCount + 1;

    state = state.copyWith(count: newCount);

    // Check and trigger alert
    final alertService = _ref.read(alertServiceProvider);
    final shouldAlert = alertService.shouldAlert(
      previousCount: previousCount,
      newCount: newCount,
      threshold: state.threshold,
      repeatInterval: state.repeatInterval,
    );

    if (shouldAlert) {
      await alertService.triggerAlert();
    }

    // Play tap feedback
    final settings = _ref.read(settingsProvider);
    final tapService = _ref.read(tapFeedbackServiceProvider);
    await tapService.playTapFeedback(settings.soundMode);
  }

  Future<void> decrement() async {
    if (state.count <= 0) return; // Prevent negative counts

    state = state.copyWith(count: state.count - 1);

    // Play light haptic for undo
    final settings = _ref.read(settingsProvider);
    final tapService = _ref.read(tapFeedbackServiceProvider);
    await tapService.playTapFeedback(settings.soundMode);
  }

  void reset({bool keepSessionStart = false}) {
    state = state.copyWith(
      count: 0,
      sessionStart: keepSessionStart ? state.sessionStart : DateTime.now(),
    );
  }

  void setThreshold(int? value) {
    state = state.copyWith(threshold: value);
  }

  void setRepeatInterval(int? value) {
    state = state.copyWith(repeatInterval: value);
  }

  void startNewSession() {
    state = state.copyWith(count: 0, sessionStart: DateTime.now());
  }
}
