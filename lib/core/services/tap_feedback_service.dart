import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../domain/models/enums.dart';

/// What a counting tap feels and sounds like, per [SoundMode].
///
/// Each mode does exactly what its name says and nothing more: Mute is silent
/// and still, Sound only clicks, Vibrate only buzzes, and both does one of
/// each. The tap zone must not add feedback of its own on top (Material's
/// InkWell clicks on every Android tap unless told not to), or Mute is not
/// silent.
class TapFeedbackService {
  Future<void> init() async {}

  Future<void> playTapFeedback(SoundMode mode) async {
    switch (mode) {
      case SoundMode.mute:
        break;
      case SoundMode.sound:
        await _click();
      case SoundMode.vibrate:
        await _buzz();
      case SoundMode.soundAndVibrate:
        await Future.wait([_click(), _buzz()]);
    }
  }

  Future<void> _click() => SystemSound.play(switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.android => SystemSoundType.click,
    _ => SystemSoundType.alert,
  });

  /// One haptic per tap. On Android the light-impact tick (VIRTUAL_KEY) was
  /// too faint to feel under a click, so it gets the platform's firmer
  /// long-press buzz. iPhone keeps the light tap, which is distinct there.
  Future<void> _buzz() => switch (defaultTargetPlatform) {
    TargetPlatform.android => HapticFeedback.vibrate(),
    TargetPlatform.iOS => HapticFeedback.lightImpact(),
    _ => Future.value(),
  };

  void dispose() {}
}
