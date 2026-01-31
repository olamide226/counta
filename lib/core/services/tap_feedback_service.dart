import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

import '../../domain/models/enums.dart';

class TapFeedbackService {
  final AudioPlayer _player = AudioPlayer();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    // Preload would happen here if we had audio assets
    _initialized = true;
  }

  Future<void> playTapFeedback(SoundMode mode) async {
    switch (mode) {
      case SoundMode.mute:
        break;
      case SoundMode.sound:
        await _playSound();
      case SoundMode.vibrate:
        await _vibrate();
      case SoundMode.soundAndVibrate:
        await Future.wait([_playSound(), _vibrate()]);
    }
  }

  Future<void> _playSound() async {
    // Placeholder - would play actual sound file
    // await _player.play(AssetSource('sounds/tap.mp3'));
  }

  Future<void> _vibrate() async {
    await HapticFeedback.lightImpact();
  }

  void dispose() {
    _player.dispose();
  }
}
