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

/// Per-phrase counts in setup order, ready to render.
///
/// Every phrase is listed even when it never matched, because a phrase sitting
/// at zero is the most useful thing the breakdown can tell anyone: it means
/// that one is not being heard. Counts recorded against a phrase that is no
/// longer in the set still appear, after the rest, so the rows always add up
/// to the voice total.
List<({String phrase, int count})> phraseBreakdown(
  List<String> phrases,
  Map<String, int> counts,
) {
  return [
    for (final phrase in phrases) (phrase: phrase, count: counts[phrase] ?? 0),
    for (final entry in counts.entries)
      if (!phrases.contains(entry.key)) (phrase: entry.key, count: entry.value),
  ];
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
    this.phraseCounts = const [],
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

  /// Per-phrase counts, from [phraseBreakdown]. Rendered only when there is
  /// more than one phrase — with one, the breakdown would just restate the
  /// voice count.
  final List<({String phrase, int count})> phraseCounts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
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
          if (phraseCounts.length > 1) ...[
            const SizedBox(height: 12),
            Divider(
              height: 1,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.2),
            ),
            const SizedBox(height: 8),
            for (final entry in phraseCounts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        '\u201c${entry.phrase}\u201d',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${entry.count}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
