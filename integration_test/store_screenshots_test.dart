// Takes the App Store / Play screenshots from the real screens, with demo
// data: a minutes balance, the three packs, saved sessions and a voice session
// that is counting. Run with `make store-screenshots` (a simulator or device id
// in DEVICE), which builds with STORE_SCREENSHOTS so the app shows its
// release name and no debug tools.

import 'package:counta/app.dart';
import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/domain/validation/phrase_validator.dart';
import 'package:counta/state/providers/counter_provider.dart';
import 'package:counta/state/providers/hive_providers.dart';
import 'package:counta/state/providers/minute_store_provider.dart';
import 'package:counta/state/providers/sessions_provider.dart';
import 'package:counta/state/providers/services_provider.dart';
import 'package:counta/state/providers/settings_provider.dart';
import 'package:counta/state/providers/supabase_providers.dart';
import 'package:counta/state/providers/voice_minutes_provider.dart';
import 'package:counta/ui/widgets/tap_zone.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/helpers/fake_counting_engine.dart';
import '../test/helpers/fake_minute_store.dart';
import '../test/helpers/mock_repositories.dart';
import '../test/helpers/session_factory.dart';
import '../test/helpers/voice_fakes.dart';

const _phrases = [
  'I am grateful for today',
  'Thank you Lord',
  'Peace be with you',
];

PhraseSpec _spec(String raw) => PhraseValidator().validate(raw).phraseSpec!;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('store screenshots', (tester) async {
    final blocks = FakeBlockService(balance: 186);
    final engine = FakeCountingEngine();
    final container = ProviderContainer(
      overrides: [
        supabaseSessionProvider.overrideWith((ref) async => null),
        // No permission prompt over the screens.
        notificationServiceProvider.overrideWithValue(
          MockNotificationService(),
        ),
        voiceMinutesProvider.overrideWith(
          (ref) => VoiceMinutesNotifier(blocks, pause: (_) async {}),
        ),
        minuteStoreProvider.overrideWithValue(FakeMinuteStore(credits: blocks)),
        voiceEngineFactoryProvider.overrideWithValue(() => engine),
      ],
    );
    addTearDown(container.dispose);

    await container.read(hiveInitProvider.future);
    await container.read(settingsProvider.notifier).markVoiceDisclosureSeen();
    final sessions = container.read(sessionsProvider.notifier);
    final now = DateTime.now();
    final seeded = [
      ('Thank you Lord', 324, 0, 41, 17),
      ('I am grateful for today', 108, 1, 18, 6),
      ('Peace be with you', 216, 2, 27, 9),
      ('Om mani padme hum', 1008, 3, 74, null),
    ];
    for (final (i, row) in seeded.indexed) {
      final (phrase, count, daysAgo, minutes, voiceMinutes) = row;
      final start = DateTime(now.year, now.month, now.day - daysAgo, 6, 30);
      await sessions.saveSession(
        testSession(
          id: 'demo-$i',
          mantra: phrase,
          phrase: voiceMinutes == null ? null : phrase,
          startedAt: start,
          endedAt: start.add(Duration(minutes: minutes)),
          finalCount: count,
          voiceCount: voiceMinutes == null ? null : count - 3,
          manualCount: voiceMinutes == null ? null : 3,
          completed: true,
          creditsConsumed: voiceMinutes,
          threshold: 108,
        ),
      );
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const App()),
    );
    await tester.pumpAndSettle();

    // A watcher on the host (`make store-screenshots`) takes the picture with
    // `simctl io screenshot` when it sees this line, status bar included;
    // Flutter's own capture comes back blank on iOS. The voice banner animates
    // for as long as it listens, so that screen is pumped, not settled.
    Future<void> shot(String name, {bool settle = true}) async {
      if (settle) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump(const Duration(seconds: 1));
      }
      debugPrint('STORE_SHOT $name');
      await Future<void>.delayed(const Duration(seconds: 4));
    }

    // 1. Tap counting: the whole screen is the counter.
    for (var i = 0; i < 27; i++) {
      await tester.tap(find.byType(TapZone));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await shot('03_tap');

    // 2. Phrase setup with several phrases.
    final controller = container.read(sessionControllerProvider);
    controller.reset();
    await tester.tap(find.byIcon(Icons.mic_none_rounded));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.first, _phrases[0]);
    for (final phrase in _phrases.skip(1)) {
      await tester.tap(find.text('Add another phrase'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, phrase);
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await shot('02_phrases');
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 3. Counting by voice, mid-session.
    await controller.startVoiceSession(
      PhraseSet([for (final p in _phrases) _spec(p)]),
    );
    await tester.pump(const Duration(seconds: 1));
    for (var i = 1; i <= 64; i++) {
      engine.emitVoiceCount(seq: i, phrase: _phrases[i % 3]);
      await tester.pump(const Duration(milliseconds: 5));
    }
    await shot('01_voice', settle: false);
    await controller.stopVoiceSession();
    await tester.pumpAndSettle();

    // 4. Voice minutes and the packs.
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Voice minutes'));
    await tester.pumpAndSettle();
    await shot('04_minutes');
    await tester.tapAt(const Offset(20, 60));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 5. History.
    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();
    await shot('05_history');
  });
}
