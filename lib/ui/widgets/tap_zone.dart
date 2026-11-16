import 'package:flutter/material.dart';

class TapZone extends StatelessWidget {
  const TapZone({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: colorScheme.primaryContainer.withValues(alpha: 0.3),
      child: InkWell(
        onTap: onTap,
        // The tap's sound and vibration come from the user's chosen mode
        // (TapFeedbackService). InkWell's own Android click would sound even
        // on Mute.
        enableFeedback: false,
        child: Center(
          child: Icon(
            Icons.touch_app_rounded,
            size: 64,
            color: colorScheme.primary,
          ),
        ),
      ),
    );
  }
}
