import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:counta/domain/models/app_settings.dart';
import 'package:counta/state/providers/counter_provider.dart';
import 'package:counta/state/providers/settings_provider.dart';

class MockSettingsRepository {
  AppSettings getSettings() => AppSettings.defaults();
  Future<void> saveSettings(AppSettings settings) async {}
}

void main() {
  group('Counter Widget', () {
    testWidgets('Counter starts at 0', (WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            (ref) => SettingsNotifier(MockSettingsRepository()),
          ),
        ],
      );
      addTearDown(container.dispose);

      final state = container.read(counterProvider);
      expect(state.count, 0);
    });

    testWidgets('Counter state can be incremented', (
      WidgetTester tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            (ref) => SettingsNotifier(MockSettingsRepository()),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(counterProvider.notifier).increment();
      final state = container.read(counterProvider);
      expect(state.count, 1);
    });
  });
}
