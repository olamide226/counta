import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:counta/state/providers/counter_provider.dart';
import 'package:counta/state/providers/services_provider.dart';
import 'package:counta/state/providers/settings_provider.dart';

import 'helpers/mock_repositories.dart';

void main() {
  ProviderContainer container() {
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(
          (ref) => SettingsNotifier(MockSettingsRepository()),
        ),
        // The real one talks to the platform, which never answers under
        // testWidgets' fake clock.
        tapFeedbackServiceProvider.overrideWithValue(MockTapFeedbackService()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('Counter Widget', () {
    testWidgets('Counter starts at 0', (WidgetTester tester) async {
      expect(container().read(counterProvider).count, 0);
    });

    testWidgets('Counter state can be incremented', (
      WidgetTester tester,
    ) async {
      final c = container();
      await c.read(counterProvider.notifier).increment();
      expect(c.read(counterProvider).count, 1);
    });
  });
}
