import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:counta/state/providers/counter_provider.dart';
import 'package:counta/state/providers/settings_provider.dart';
import 'package:counta/state/providers/services_provider.dart';
import 'package:counta/core/services/tap_feedback_service.dart';
import 'package:counta/domain/models/app_settings.dart';
import 'package:counta/domain/models/enums.dart';

class MockSettingsRepository {
  AppSettings getSettings() => AppSettings.defaults();
  Future<void> saveSettings(AppSettings settings) async {}
}

class MockTapFeedbackService implements TapFeedbackService {
  @override
  Future<void> init() async {}

  @override
  Future<void> playTapFeedback(SoundMode mode) async {}

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CounterProvider', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            (ref) => SettingsNotifier(MockSettingsRepository()),
          ),
          tapFeedbackServiceProvider.overrideWithValue(
            MockTapFeedbackService(),
          ),
        ],
      );
    });

    tearDown(() {
      container.dispose();
    });

    test('initial state has count of 0', () {
      final state = container.read(counterProvider);
      expect(state.count, 0);
    });

    test(
      'initializes with default threshold and repeat interval from settings',
      () {
        final state = container.read(counterProvider);
        expect(state.threshold, 100);
        expect(state.repeatInterval, 100);
      },
    );

    test('increment increases count by 1', () async {
      final notifier = container.read(counterProvider.notifier);

      await notifier.increment();

      final state = container.read(counterProvider);
      expect(state.count, 1);
    });

    test('multiple increments work correctly', () async {
      final notifier = container.read(counterProvider.notifier);

      for (int i = 0; i < 5; i++) {
        await notifier.increment();
      }

      final state = container.read(counterProvider);
      expect(state.count, 5);
    });

    test('decrement decreases count by 1', () async {
      final notifier = container.read(counterProvider.notifier);

      // Increment to 3
      await notifier.increment();
      await notifier.increment();
      await notifier.increment();

      // Decrement once
      await notifier.decrement();

      final state = container.read(counterProvider);
      expect(state.count, 2);
    });

    test('decrement does not go below 0', () async {
      final notifier = container.read(counterProvider.notifier);

      // Try to decrement from 0
      await notifier.decrement();

      final state = container.read(counterProvider);
      expect(state.count, 0);
    });

    test('decrement from 1 goes to 0', () async {
      final notifier = container.read(counterProvider.notifier);

      await notifier.increment();
      await notifier.decrement();

      final state = container.read(counterProvider);
      expect(state.count, 0);
    });

    test('reset sets count to 0', () async {
      final notifier = container.read(counterProvider.notifier);

      // Increment to 10
      for (int i = 0; i < 10; i++) {
        await notifier.increment();
      }

      notifier.reset();

      final state = container.read(counterProvider);
      expect(state.count, 0);
    });

    test('reset creates new session start by default', () {
      final notifier = container.read(counterProvider.notifier);
      final initialSessionStart = container.read(counterProvider).sessionStart;

      // Wait a bit to ensure time difference
      Future.delayed(const Duration(milliseconds: 10), () {
        notifier.reset();
        final newSessionStart = container.read(counterProvider).sessionStart;

        expect(newSessionStart.isAfter(initialSessionStart), true);
      });
    });

    test('reset with keepSessionStart preserves session start time', () {
      final notifier = container.read(counterProvider.notifier);
      final initialSessionStart = container.read(counterProvider).sessionStart;

      notifier.reset(keepSessionStart: true);
      final newSessionStart = container.read(counterProvider).sessionStart;

      expect(newSessionStart, initialSessionStart);
    });

    test('setThreshold updates threshold', () {
      final notifier = container.read(counterProvider.notifier);

      notifier.setThreshold(108);

      final state = container.read(counterProvider);
      expect(state.threshold, 108);
    });

    test('setRepeatInterval updates repeat interval', () {
      final notifier = container.read(counterProvider.notifier);

      notifier.setRepeatInterval(25);

      final state = container.read(counterProvider);
      expect(state.repeatInterval, 25);
    });

    test('startNewSession resets count and creates new session start', () {
      final notifier = container.read(counterProvider.notifier);

      // Increment count
      notifier.increment();
      notifier.increment();

      final initialSessionStart = container.read(counterProvider).sessionStart;

      Future.delayed(const Duration(milliseconds: 10), () {
        notifier.startNewSession();

        final state = container.read(counterProvider);
        expect(state.count, 0);
        expect(state.sessionStart.isAfter(initialSessionStart), true);
      });
    });

    test('count persists across threshold changes', () async {
      final notifier = container.read(counterProvider.notifier);

      await notifier.increment();
      await notifier.increment();
      await notifier.increment();

      notifier.setThreshold(50);

      final state = container.read(counterProvider);
      expect(state.count, 3);
      expect(state.threshold, 50);
    });

    test('increment and decrement can be alternated', () async {
      final notifier = container.read(counterProvider.notifier);

      await notifier.increment(); // 1
      await notifier.increment(); // 2
      await notifier.decrement(); // 1
      await notifier.increment(); // 2
      await notifier.increment(); // 3
      await notifier.decrement(); // 2

      final state = container.read(counterProvider);
      expect(state.count, 2);
    });
  });
}
