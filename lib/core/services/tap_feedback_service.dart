import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../domain/models/enums.dart';

class TapFeedbackService {
  final AudioPlayer _player = AudioPlayer();
  bool _initialized = false;

  // Check if platform supports haptic feedback
  bool get _supportsHaptics {
    if (kIsWeb) return false;
    return Platform.isIOS || Platform.isAndroid;
  }

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
    // When you add audio assets:
    // await _player.play(AssetSource('sounds/tap.mp3'));
  }

  Future<void> _vibrate() async {
    if (_supportsHaptics) {
      await HapticFeedback.lightImpact();
    }
    // Desktop/web: silent (visual feedback only)
  }

  void dispose() {
    _player.dispose();
  }
}
