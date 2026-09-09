import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

import 'package:counta/core/services/counting/audio_source.dart';

void main() {
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
