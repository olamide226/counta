import 'package:flutter_test/flutter_test.dart';

import 'package:counta/core/services/screen_wake_service.dart';

void main() {
  group('ScreenWakeService', () {
    late List<bool> toggles;
    late ScreenWakeService service;

    setUp(() {
      toggles = [];
      service = ScreenWakeService(
        toggle: (enable) async => toggles.add(enable),
      );
    });

    test('acquires once even when asked repeatedly', () async {
      await service.acquire();
      await service.acquire();
      await service.acquire();

      expect(service.isHeld, isTrue);
      expect(toggles, [true]);
    });

    test('releasing without acquiring is a no-op', () async {
      await service.release();

      expect(service.isHeld, isFalse);
      expect(toggles, isEmpty);
    });

    test('setActive mirrors session state', () async {
      await service.setActive(true);
      expect(service.isHeld, isTrue);

      await service.setActive(false);
      expect(service.isHeld, isFalse);

      // A leaked wakelock drains the battery long after the session ends, so
      // the release must actually reach the platform.
      expect(toggles, [true, false]);
    });

    test('can be re-acquired after release', () async {
      await service.acquire();
      await service.release();
      await service.acquire();

      expect(service.isHeld, isTrue);
      expect(toggles, [true, false, true]);
    });

    test('a failed acquire leaves the service retryable, not stuck held',
        () async {
      var shouldFail = true;
      final flaky = ScreenWakeService(
        toggle: (enable) async {
          if (shouldFail) throw Exception('platform unavailable');
          toggles.add(enable);
        },
      );

      await flaky.acquire();
      expect(flaky.isHeld, isFalse,
          reason: 'a failed acquire must not latch the held flag');

      shouldFail = false;
      await flaky.acquire();
      expect(flaky.isHeld, isTrue);
      expect(toggles, [true]);
    });

    test('a failed release still clears the flag', () async {
      var failOnRelease = false;
      final flaky = ScreenWakeService(
        toggle: (enable) async {
          if (!enable && failOnRelease) throw Exception('platform unavailable');
        },
      );

      await flaky.acquire();
      failOnRelease = true;
      await flaky.release();

      expect(flaky.isHeld, isFalse);
    });
  });
}
