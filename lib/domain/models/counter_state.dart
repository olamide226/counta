class CounterState {
  const CounterState({
    required this.count,
    required this.sessionStart,
    this.threshold,
    this.repeatInterval,
  });

  final int count;
  final int? threshold;
  final int? repeatInterval;
  final DateTime sessionStart;

  CounterState copyWith({
    int? count,
    int? threshold,
    int? repeatInterval,
    DateTime? sessionStart,
  }) {
    return CounterState(
      count: count ?? this.count,
      threshold: threshold ?? this.threshold,
      repeatInterval: repeatInterval ?? this.repeatInterval,
      sessionStart: sessionStart ?? this.sessionStart,
    );
  }
}
