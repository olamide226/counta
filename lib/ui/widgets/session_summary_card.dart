import 'package:flutter/material.dart';

/// How a session's counts read as one line: `40 by voice · 2 by tap`, or just
/// the total when there is no split to show.
///
/// Lived in three widgets, worded slightly differently in each.
String sessionBreakdownLabel({
  required int total,
  required int? voiceCount,
  required int? manualCount,
}) {
  if (voiceCount == null && manualCount == null) return '$total counts';
  return '${voiceCount ?? 0} by voice · ${manualCount ?? 0} by tap';
}

/// The phrase-and-counts summary shown wherever a session is presented back to
/// the user: the recovery sheet, the save sheet and the session detail screen.
class SessionSummaryCard extends StatelessWidget {
  const SessionSummaryCard({
    super.key,
    required this.title,
    required this.total,
    this.voiceCount,
    this.manualCount,
    this.isVoiceSession = false,
    this.showTotal = true,
  });

  /// The phrase or mantra this session was counted under.
  final String title;
  final int total;
  final int? voiceCount;
  final int? manualCount;
  final bool isVoiceSession;

  /// Whether to show the total alongside the breakdown. The save sheet already
  /// prints the count above the card.
  final bool showTotal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            isVoiceSession
                ? Icons.graphic_eq_rounded
                : Icons.touch_app_outlined,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sessionBreakdownLabel(
                    total: total,
                    voiceCount: voiceCount,
                    manualCount: manualCount,
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (showTotal)
            Text(
              '$total',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    );
  }
}
