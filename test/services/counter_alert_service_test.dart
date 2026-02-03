import 'package:flutter_test/flutter_test.dart';
import 'package:counta/core/services/counter_alert_service.dart';

void main() {
  group('CounterAlertService', () {
    late CounterAlertService service;

    setUp(() {
      service = CounterAlertService();
    });

    group('shouldAlert', () {
      test('returns false when threshold is null', () {
        final result = service.shouldAlert(
          previousCount: 99,
          newCount: 100,
          threshold: null,
          repeatInterval: null,
        );

        expect(result, false);
      });

      test('returns false when threshold is 0 or negative', () {
        expect(
          service.shouldAlert(
            previousCount: 0,
            newCount: 1,
            threshold: 0,
            repeatInterval: null,
          ),
          false,
        );

        expect(
          service.shouldAlert(
            previousCount: 0,
            newCount: 1,
            threshold: -10,
            repeatInterval: null,
          ),
          false,
        );
      });

      test('returns true when reaching threshold', () {
        final result = service.shouldAlert(
          previousCount: 99,
          newCount: 100,
          threshold: 100,
          repeatInterval: null,
        );

        expect(result, true);
      });

      test('returns false when not at threshold', () {
        final result = service.shouldAlert(
          previousCount: 98,
          newCount: 99,
          threshold: 100,
          repeatInterval: null,
        );

        expect(result, false);
      });

      test('returns true at repeat intervals after threshold', () {
        // At 100 (threshold)
        expect(
          service.shouldAlert(
            previousCount: 99,
            newCount: 100,
            threshold: 100,
            repeatInterval: 25,
          ),
          true,
        );

        // At 125 (threshold + 1 * repeatInterval)
        expect(
          service.shouldAlert(
            previousCount: 124,
            newCount: 125,
            threshold: 100,
            repeatInterval: 25,
          ),
          true,
        );

        // At 150 (threshold + 2 * repeatInterval)
        expect(
          service.shouldAlert(
            previousCount: 149,
            newCount: 150,
            threshold: 100,
            repeatInterval: 25,
          ),
          true,
        );
      });

      test('returns false between repeat intervals', () {
        expect(
          service.shouldAlert(
            previousCount: 100,
            newCount: 101,
            threshold: 100,
            repeatInterval: 25,
          ),
          false,
        );

        expect(
          service.shouldAlert(
            previousCount: 110,
            newCount: 111,
            threshold: 100,
            repeatInterval: 25,
          ),
          false,
        );
      });

      test('ignores repeat interval when null or 0', () {
        // After threshold with null repeatInterval
        expect(
          service.shouldAlert(
            previousCount: 100,
            newCount: 101,
            threshold: 100,
            repeatInterval: null,
          ),
          false,
        );

        // After threshold with 0 repeatInterval
        expect(
          service.shouldAlert(
            previousCount: 100,
            newCount: 101,
            threshold: 100,
            repeatInterval: 0,
          ),
          false,
        );
      });

      test('handles edge case: threshold equals repeat interval', () {
        // At 50 (threshold)
        expect(
          service.shouldAlert(
            previousCount: 49,
            newCount: 50,
            threshold: 50,
            repeatInterval: 50,
          ),
          true,
        );

        // At 100 (threshold + repeatInterval)
        expect(
          service.shouldAlert(
            previousCount: 99,
            newCount: 100,
            threshold: 50,
            repeatInterval: 50,
          ),
          true,
        );
      });

      test('handles large numbers correctly', () {
        expect(
          service.shouldAlert(
            previousCount: 9999,
            newCount: 10000,
            threshold: 10000,
            repeatInterval: null,
          ),
          true,
        );

        expect(
          service.shouldAlert(
            previousCount: 10099,
            newCount: 10100,
            threshold: 10000,
            repeatInterval: 100,
          ),
          true,
        );
      });
    });

    group('triggerAlert', () {
      test('completes without error', () async {
        // This test mainly ensures the method doesn't throw
        await expectLater(service.triggerAlert(), completes);
      });
    });
  });
}
