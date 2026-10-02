import 'dart:async';

import 'package:flutter/material.dart';

import '../../state/providers/voice_minutes_provider.dart';
import 'voice_session_banner.dart';

/// "1 minute", "23 minutes".
String minutesCount(int minutes) =>
    minutes == 1 ? '1 minute' : '$minutes minutes';

/// The balance, where a voice session is about to start.
class VoiceMinutesPanel extends StatelessWidget {
  const VoiceMinutesPanel({
    super.key,
    required this.minutesLeft,
    required this.onGetMore,
  });

  final int minutesLeft;
  final VoidCallback onGetMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.timer_outlined, size: 20, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$minutesLeft voice '
                  '${minutesLeft == 1 ? 'minute' : 'minutes'}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Only used while voice counting is on',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          TextButton(onPressed: onGetMore, child: const Text('Get more')),
        ],
      ),
    );
  }
}

/// Shown instead of [VoiceMinutesPanel] when there are too few minutes to
/// start. Says what is short and what still works, before the user has tried
/// and been refused.
class NoVoiceMinutesNotice extends StatelessWidget {
  const NoVoiceMinutesNotice({
    super.key,
    required this.balance,
    required this.required,
  });

  final int balance;
  final int required;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const foreground = VoiceWarningColors.foreground;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VoiceWarningColors.background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.timer_off_outlined, size: 20, color: foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  balance <= 0
                      ? 'No voice minutes left'
                      : 'Not enough voice minutes',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  balance <= 0
                      ? 'Voice counting needs minutes. You can still count by '
                            'tapping.'
                      : 'Voice counting needs $required minutes to start, and '
                            'you have $balance. You can still count by '
                            'tapping.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Takes the voice banner's place when a running session ran out of minutes.
///
/// The banner used to just disappear, which left the user wondering whether
/// the count had gone with it. This says what stopped, that the count is
/// safe, and what to do next.
class VoicePausedBanner extends StatelessWidget {
  const VoicePausedBanner({
    super.key,
    required this.voiceCount,
    required this.manualCount,
    required this.onGetMinutes,
    required this.onDismiss,
  });

  final int voiceCount;
  final int manualCount;
  final VoidCallback onGetMinutes;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final onContainer = scheme.onSurface;

    return Material(
      color: scheme.surfaceContainerHighest,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                liveRegion: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Icon(
                        Icons.mic_off_outlined,
                        size: 22,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Voice paused',
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: onContainer,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              "You're out of voice minutes. Your count is "
                              'safe, and tapping still works.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: onDismiss,
                      icon: const Icon(Icons.close_rounded, size: 20),
                      tooltip: 'Dismiss',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          VoiceCountPill(
                            icon: Icons.graphic_eq_rounded,
                            label: '$voiceCount by voice',
                            onContainer: onContainer,
                          ),
                          VoiceCountPill(
                            icon: Icons.touch_app_outlined,
                            label: '$manualCount by tap',
                            onContainer: onContainer,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: onGetMinutes,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Get minutes'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What a stop cost, in words.
({String title, String? detail}) describeVoiceUsage(VoiceUsage usage) {
  final title = usage.used == 0
      ? 'No voice minutes used'
      : 'Used ${usage.used} voice ${usage.used == 1 ? 'minute' : 'minutes'}';
  final left = usage.left;
  final detail = [
    if (usage.returned > 0)
      '${usage.returned} unused '
          '${usage.returned == 1 ? 'minute' : 'minutes'} returned.',
    if (left != null) '$left left.',
  ].join(' ');
  return (title: title, detail: detail.isEmpty ? null : detail);
}

/// One quiet line in the banner's place after a voice session stops: what it
/// cost, what came back, what is left. Goes away by itself.
class VoiceUsageStrip extends StatefulWidget {
  const VoiceUsageStrip({
    super.key,
    required this.usage,
    required this.onDismiss,
    this.visibleFor = const Duration(seconds: 10),
  });

  final VoiceUsage usage;
  final VoidCallback onDismiss;

  /// How long the line stays before it dismisses itself.
  final Duration visibleFor;

  @override
  State<VoiceUsageStrip> createState() => _VoiceUsageStripState();
}

class _VoiceUsageStripState extends State<VoiceUsageStrip> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.visibleFor, widget.onDismiss);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final words = describeVoiceUsage(widget.usage);

    return Material(
      color: scheme.surfaceContainerHighest,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
          child: Row(
            children: [
              Icon(Icons.timer_outlined, size: 22, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          words.title,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (words.detail case final detail?)
                          Text(
                            detail,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                onPressed: widget.onDismiss,
                icon: const Icon(Icons.close_rounded, size: 20),
                tooltip: 'Dismiss',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
