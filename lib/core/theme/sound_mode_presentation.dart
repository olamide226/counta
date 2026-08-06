import 'package:flutter/material.dart';

import '../../domain/models/enums.dart';

/// One place for how a [SoundMode] is shown to the user.
///
/// This mapping previously lived in four screens and had already drifted: the
/// same mode showed a different icon and a different label depending on which
/// screen you were looking at. It lives in `core/theme` rather than beside the
/// enum so `domain/` stays free of Flutter imports.
extension SoundModePresentation on SoundMode {
  IconData get icon => switch (this) {
        SoundMode.soundAndVibrate => Icons.volume_up,
        SoundMode.sound => Icons.volume_down,
        SoundMode.vibrate => Icons.vibration,
        SoundMode.mute => Icons.volume_off,
      };

  String get label => switch (this) {
        SoundMode.soundAndVibrate => 'Sound & Vibrate',
        SoundMode.sound => 'Sound Only',
        SoundMode.vibrate => 'Vibrate Only',
        SoundMode.mute => 'Mute',
      };
}
