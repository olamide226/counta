import 'package:counta/core/services/tap_feedback_service.dart';
import 'package:counta/domain/models/enums.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<List<String>> play(SoundMode mode, TargetPlatform platform) async {
    debugDefaultTargetPlatformOverride = platform;
    await TapFeedbackService().playTapFeedback(mode);
    return calls.map((c) => '${c.method} ${c.arguments}').toList();
  }

  const click = 'SystemSound.play SystemSoundType.click';
  const haptics = {
    // Android's firm long-press buzz; iPhone's light tap.
    TargetPlatform.android: 'HapticFeedback.vibrate null',
    TargetPlatform.iOS: 'HapticFeedback.vibrate HapticFeedbackType.lightImpact',
  };

  for (final MapEntry(key: platform, value: buzz) in haptics.entries) {
    group(platform.name, () {
      test('mute makes no sound and no vibration', () async {
        expect(await play(SoundMode.mute, platform), isEmpty);
      });

      test('sound only clicks', () async {
        expect(await play(SoundMode.sound, platform), [click]);
      });

      test('vibrate only vibrates', () async {
        expect(await play(SoundMode.vibrate, platform), [buzz]);
      });

      test('sound and vibrate does one of each', () async {
        expect(
          await play(SoundMode.soundAndVibrate, platform),
          unorderedEquals([click, buzz]),
        );
      });
    });
  }
}
