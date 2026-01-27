import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/counter_state.dart';

final counterProvider = StateNotifierProvider<CounterNotifier, CounterState>(
  (ref) => CounterNotifier(),
);

class CounterNotifier extends StateNotifier<CounterState> {
  CounterNotifier()
    : super(CounterState(count: 0, sessionStart: DateTime.now()));

  void increment() {
    state = state.copyWith(count: state.count + 1);
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
