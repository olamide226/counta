class CounterState {
  const CounterState({
    required this.count,
    required this.sessionStart,
    this.mantra,
    this.threshold,
    this.repeatInterval,
  });

  final int count;
  final int? threshold;
  final int? repeatInterval;
  final DateTime sessionStart;

  /// The label the session is being counted under, when it came from a saved
  /// or recovered session. Null for a fresh session, which has no name until
  /// the user gives it one in the save sheet.
  final String? mantra;

  CounterState copyWith({
    int? count,
    int? threshold,
    int? repeatInterval,
    DateTime? sessionStart,
    String? mantra,
  }) {
    return CounterState(
      count: count ?? this.count,
      threshold: threshold ?? this.threshold,
      repeatInterval: repeatInterval ?? this.repeatInterval,
      sessionStart: sessionStart ?? this.sessionStart,
      mantra: mantra ?? this.mantra,
    );
  }
}
