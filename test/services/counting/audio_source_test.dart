import 'dart:async';
import 'dart:typed_data';

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Grants permission, then [startStream] either throws or hands back a
/// stream that never delivers.
class _ScriptedRecorder implements AudioRecorder {
  _ScriptedRecorder({this.refuseToStart = false});

  final bool refuseToStart;
  final _frames = StreamController<Uint8List>();

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    if (refuseToStart) throw StateError('cannot start recording now');
    return _frames.stream;
  }

  @override
  Future<bool> isRecording() async => false;

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a recorder that refuses to start says so on the stream', () async {
    // Regression: the refusal was thrown nowhere anyone listened, so no
    // frame and no error ever came, and a resume waiting on either waited
    // for ever.
    final source = AudioSource(
      recorder: _ScriptedRecorder(refuseToStart: true),
    );
    await expectLater(source.start(), emitsError(isA<StateError>()));
  });

  test(
    'a silent microphone is reported for as long as it stays silent',
    () async {
      // Regression: the stall was raised once and the watchdog stopped. One
      // that landed while the engine was busy was lost, and the session sat
      // on "Listening" with a dead microphone.
      final source = AudioSource(recorder: _ScriptedRecorder());
      final stalls = <Object>[];
      final sub = source.start().listen((_) {}, onError: stalls.add);

      await Future<void>.delayed(const Duration(milliseconds: 7300));

      expect(
        stalls.whereType<AudioSourceStalled>().length,
        greaterThanOrEqualTo(2),
      );
      await sub.cancel();
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

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

  group('AudioSource.recordConfig iOS audio session policy', () {
    final options = AudioSource.recordConfig(16000).iosConfig.categoryOptions;

    test('mixes with other audio instead of stopping it', () {
      // Without mixWithOthers, starting a session takes the audio route
      // exclusively and pauses the user's music or podcast.
      expect(options, contains(IosAudioCategoryOption.mixWithOthers));
    });

    test('allows haptics and system sounds while recording', () {
      // The app plays a system click on every tap. Without this, iOS raises an
      // interruption and record's observer pauses capture permanently.
      expect(
        AudioSource.recordConfig(
          16000,
        ).iosConfig.allowHapticsAndSystemSoundsDuringRecording,
        isTrue,
      );
    });

    test('survives the microphone being muted', () {
      expect(
        options,
        contains(IosAudioCategoryOption.overrideMutedMicrophoneInterruption),
      );
    });

    test('routes to speaker and permits Bluetooth headsets', () {
      expect(options, contains(IosAudioCategoryOption.defaultToSpeaker));
      expect(options, contains(IosAudioCategoryOption.allowBluetooth));
      expect(options, contains(IosAudioCategoryOption.allowBluetoothA2DP));
    });

    test('captures 16 kHz mono PCM16, as Deepgram is told to expect', () {
      final config = AudioSource.recordConfig(16000);

      expect(config.encoder, AudioEncoder.pcm16bits);
      expect(config.sampleRate, 16000);
      expect(config.numChannels, 1);
    });

    test('honours the requested sample rate', () {
      expect(AudioSource.recordConfig(48000).sampleRate, 48000);
    });
  });
}
