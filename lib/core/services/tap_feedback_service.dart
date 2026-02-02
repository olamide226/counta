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
    // Use system click sound on iOS and Android
    if (Platform.isIOS || Platform.isAndroid) {
      await SystemSound.play(SystemSoundType.click);
    } else {
      await SystemSound.play(SystemSoundType.alert);
    }
    // Sound mode uses subtle haptic as well
    if (_supportsHaptics) {
      await HapticFeedback.selectionClick();
    }
  }

  Future<void> _vibrate() async {
    if (_supportsHaptics) {
      await HapticFeedback.lightImpact();
    }
  }

  void dispose() {
    _player.dispose();
  }
}
