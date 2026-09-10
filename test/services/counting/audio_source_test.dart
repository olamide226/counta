import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

import 'package:counta/core/services/counting/audio_source.dart';

/// Answers the one call `AudioSource` makes before capture, and forwards
/// everything else to `noSuchMethod` so this does not have to track the
/// plugin's whole surface.
class _RefusingRecorder implements AudioRecorder {
  @override
  Future<bool> hasPermission() async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  test('a refused microphone is reported as a typed failure', () async {
    // The engine maps AudioSourcePermissionDenied to
    // EngineStatus.permissionDenied, which is what puts the settings link on
    // screen. A generic error takes the unknown-failure branch instead, so
    // this assertion is the difference between the right screen and the wrong
    // one. The engine tests cannot catch it: their fake source has always
    // raised the correct type.
    final source = AudioSource(recorder: _RefusingRecorder());

    await expectLater(
      source.start(),
      emitsError(isA<AudioSourcePermissionDenied>()),
    );
  });
}
