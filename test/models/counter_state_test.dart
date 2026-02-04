import 'package:flutter_test/flutter_test.dart';
import 'package:counta/domain/models/counter_state.dart';

void main() {
  group('CounterState', () {
    test('creates with default values', () {
      final state = CounterState(count: 0, sessionStart: DateTime.now());

      expect(state.count, 0);
      expect(state.threshold, null);
      expect(state.repeatInterval, null);
    });

    test('creates with all fields specified', () {
      final now = DateTime.now();
      final state = CounterState(
        count: 100,
        threshold: 100,
        repeatInterval: 25,
        sessionStart: now,
      );

      expect(state.count, 100);
      expect(state.threshold, 100);
      expect(state.repeatInterval, 25);
      expect(state.sessionStart, now);
    });

    test('copyWith updates specific fields', () {
      final start = DateTime.now();
      final state = CounterState(count: 0, sessionStart: start);

      final updated = state.copyWith(count: 50, threshold: 100);

      expect(updated.count, 50);
      expect(updated.threshold, 100);
      expect(updated.sessionStart, start);
    });

    test('copyWith preserves existing values when not specified', () {
      final state = CounterState(
        count: 25,
        threshold: 100,
        repeatInterval: 50,
        sessionStart: DateTime.now(),
      );

      final updated = state.copyWith(count: 30);

      expect(updated.count, 30);
      expect(updated.threshold, 100);
      expect(updated.repeatInterval, 50);
    });

    test('copyWith preserves threshold and interval when not specified', () {
      final state = CounterState(
        count: 100,
        threshold: 100,
        repeatInterval: 25,
        sessionStart: DateTime.now(),
      );

      final updated = state.copyWith(count: 150);

      expect(updated.threshold, 100);
      expect(updated.repeatInterval, 25);
      expect(updated.count, 150);
    });

    test('copyWith updates session start', () {
      final oldStart = DateTime(2026, 1, 1);
      final newStart = DateTime(2026, 2, 1);

      final state = CounterState(count: 50, sessionStart: oldStart);

      final updated = state.copyWith(sessionStart: newStart);

      expect(updated.sessionStart, newStart);
      expect(updated.count, 50);
    });

    test('handles large count values', () {
      final state = CounterState(count: 999999, sessionStart: DateTime.now());

      expect(state.count, 999999);
    });

    test('threshold and repeat interval can be zero', () {
      final state = CounterState(
        count: 0,
        threshold: 0,
        repeatInterval: 0,
        sessionStart: DateTime.now(),
      );

      expect(state.threshold, 0);
      expect(state.repeatInterval, 0);
    });
  });
}
