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

  group('Android', () {
    const android = TargetPlatform.android;
    const buzz = 'HapticFeedback.vibrate null';

    test('mute makes no sound and no vibration', () async {
      expect(await play(SoundMode.mute, android), isEmpty);
    });

    test('sound only clicks', () async {
      expect(await play(SoundMode.sound, android), [click]);
    });

    test('vibrate only buzzes', () async {
      expect(await play(SoundMode.vibrate, android), [buzz]);
    });

    test('sound and vibrate does one of each', () async {
      expect(
        await play(SoundMode.soundAndVibrate, android),
        unorderedEquals([click, buzz]),
      );
    });
  });

  group('iPhone', () {
    const ios = TargetPlatform.iOS;
    const tap = 'HapticFeedback.vibrate HapticFeedbackType.lightImpact';

    test('mute makes no sound and no vibration', () async {
      expect(await play(SoundMode.mute, ios), isEmpty);
    });

    test('sound only clicks', () async {
      expect(await play(SoundMode.sound, ios), [click]);
    });

    test('vibrate only taps', () async {
      expect(await play(SoundMode.vibrate, ios), [tap]);
    });
  });
}
