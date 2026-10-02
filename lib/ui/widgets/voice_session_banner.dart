import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/counting/counting_engine.dart';
import 'session_summary_card.dart';

/// The header shown while a voice counting session is running.
///
/// Everything here is driven by the active [ColorScheme] so the banner matches
/// whichever theme the user picked, and the stop control is a labelled button
/// rather than a bare icon — ending a session should never be a guess.
class VoiceSessionBanner extends StatefulWidget {
  const VoiceSessionBanner({
    super.key,
    required this.status,
    required this.phrases,
    required this.voiceCount,
    required this.manualCount,
    required this.onStop,
    this.phraseCounts = const {},
    this.lastMatchedPhrase,
    this.diagnostic,
    this.minutesLeft,
    this.minutesLow = false,
  });

  final EngineStatus status;

  /// Every phrase this session is listening for, in setup order.
  final List<String> phrases;

  final int voiceCount;
  final int manualCount;
  final VoidCallback onStop;

  /// Voice counts keyed by phrase, for the expandable breakdown.
  final Map<String, int> phraseCounts;

  /// The phrase the most recent count landed on, marked in the breakdown so
  /// the user can see which one the app just heard.
  final String? lastMatchedPhrase;

  final String? diagnostic;

  /// Voice minutes left, shown as a third pill. Null hides it: a build with
  /// no voice service has no minutes, and a balance that has not loaded is
  /// not worth a placeholder mid-session.
  final int? minutesLeft;

  /// Whether [minutesLeft] is few enough to draw the eye.
  final bool minutesLow;

  @override
  State<VoiceSessionBanner> createState() => _VoiceSessionBannerState();
}

class _VoiceSessionBannerState extends State<VoiceSessionBanner> {
  /// Collapsed by default: mid-session the total is what matters, and the
  /// per-phrase split is for when something looks wrong.
  bool _expanded = false;

  EngineStatus get status => widget.status;
  int get voiceCount => widget.voiceCount;
  int get manualCount => widget.manualCount;
  String? get diagnostic => widget.diagnostic;

  bool get _isMultiple => widget.phrases.length > 1;

  bool get _isListening => status == EngineStatus.live;

  bool get _isUnhealthy =>
      status == EngineStatus.reconnecting ||
      status == EngineStatus.degraded ||
      status == EngineStatus.notConfigured ||
      status == EngineStatus.error;

  String get _statusLabel => switch (status) {
    EngineStatus.live => 'Listening',
    EngineStatus.connecting => 'Connecting…',
    EngineStatus.reconnecting => 'Reconnecting…',
    EngineStatus.requestingBlock => 'Preparing…',
    EngineStatus.degraded => 'Poor connection',
    EngineStatus.exhausted => 'Out of voice minutes',
    EngineStatus.error => 'Voice counting stopped',
    EngineStatus.idle => 'Paused',
    EngineStatus.permissionDenied => 'Microphone access needed',
    EngineStatus.notConfigured => 'Voice counting unavailable',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final container = _isUnhealthy
        ? scheme.errorContainer
        : scheme.primaryContainer;
    final onContainer = _isUnhealthy
        ? scheme.onErrorContainer
        : scheme.onPrimaryContainer;
    final accent = _isUnhealthy ? scheme.error : scheme.primary;

    return Material(
      color: container,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _VoiceActivityIndicator(active: _isListening, color: accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _statusLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: onContainer.withValues(alpha: 0.75),
                            letterSpacing: 0.6,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 1),
                        _PhraseHeading(
                          label: phraseSetLabel(widget.phrases),
                          onContainer: onContainer,
                          // Only a set has anything to expand into.
                          expanded: _isMultiple ? _expanded : null,
                          onToggle: _isMultiple
                              ? () => setState(() => _expanded = !_expanded)
                              : null,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // A labelled button, so stopping is discoverable at a glance.
                  FilledButton.icon(
                    onPressed: widget.onStop,
                    icon: const Icon(Icons.stop_rounded, size: 18),
                    label: const Text('Stop'),
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: _isUnhealthy
                          ? scheme.onError
                          : scheme.onPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
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
                  if (widget.minutesLeft case final left?)
                    VoiceCountPill(
                      icon: Icons.timer_outlined,
                      label: '$left min left',
                      semanticLabel:
                          '$left voice ${left == 1 ? 'minute' : 'minutes'} left',
                      onContainer: onContainer,
                      // Quiet until it matters. Colour alone would not carry
                      // it, so the number is always there to read.
                      warning: widget.minutesLow,
                    ),
                ],
              ),
              if (_isMultiple && _expanded) ...[
                const SizedBox(height: 10),
                for (final entry in phraseBreakdown(
                  widget.phrases,
                  widget.phraseCounts,
                ))
                  _PhraseCountRow(
                    phrase: entry.phrase,
                    count: entry.count,
                    onContainer: onContainer,
                    isLatest: entry.phrase == widget.lastMatchedPhrase,
                  ),
              ],
              if (diagnostic != null) ...[
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 15,
                      color: onContainer.withValues(alpha: 0.8),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        diagnostic!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: onContainer.withValues(alpha: 0.9),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A small labelled figure in a voice banner: counts by voice, counts by
/// tap, minutes left.
class VoiceCountPill extends StatelessWidget {
  const VoiceCountPill({
    super.key,
    required this.icon,
    required this.label,
    required this.onContainer,
    this.semanticLabel,
    this.warning = false,
  });

  final IconData icon;
  final String label;
  final Color onContainer;

  /// Read out instead of [label] when the short form would not make sense
  /// spoken.
  final String? semanticLabel;

  /// Draws the pill in the warning colours instead of the banner's own.
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final foreground = warning ? VoiceWarningColors.foreground : onContainer;
    return Semantics(
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: warning
              ? VoiceWarningColors.background
              : onContainer.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: foreground.withValues(alpha: 0.8)),
            const SizedBox(width: 5),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The amber used when voice minutes are short.
///
/// `ColorScheme` has no warning role, and borrowing `error` would say
/// something has gone wrong when nothing has. One fixed pair, dark text on
/// light amber, reads on every theme in both brightnesses.
abstract final class VoiceWarningColors {
  static const background = Color(0xFFFFDDB3);
  static const foreground = Color(0xFF2A1800);
}

/// Three bars that dance while the microphone is live, and rest flat when it
/// is not — a clearer "we are hearing you" signal than a blinking dot.
class _VoiceActivityIndicator extends StatefulWidget {
  const _VoiceActivityIndicator({required this.active, required this.color});

  final bool active;
  final Color color;

  @override
  State<_VoiceActivityIndicator> createState() =>
      _VoiceActivityIndicatorState();
}

class _VoiceActivityIndicatorState extends State<_VoiceActivityIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(_VoiceActivityIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // CustomPaint rather than an AnimatedBuilder over Containers: the painter
    // repaints straight off the controller, so a session running for hours
    // rebuilds and relayouts nothing — it just redraws three rounded bars.
    return SizedBox(
      width: 22,
      height: 24,
      child: CustomPaint(
        painter: _VoiceBarsPainter(
          progress: _controller,
          color: widget.color,
          active: widget.active,
        ),
      ),
    );
  }
}

class _VoiceBarsPainter extends CustomPainter {
  _VoiceBarsPainter({
    required this.progress,
    required this.color,
    required this.active,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final Color color;
  final bool active;

  static const int _barCount = 3;
  static const double _barWidth = 4;
  static const double _minHeight = 7;
  static const double _maxExtra = 15;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: active ? 1.0 : 0.45)
      ..isAntiAlias = true;

    final gap = (size.width - _barCount * _barWidth) / (_barCount - 1);

    for (var i = 0; i < _barCount; i++) {
      final phase = progress.value * 2 * math.pi + i * 1.1;
      final wave = active ? (math.sin(phase) + 1) / 2 : 0.0;
      final height = _minHeight + wave * _maxExtra;
      final left = i * (_barWidth + gap);
      final top = (size.height - height) / 2;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, _barWidth, height),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_VoiceBarsPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.active != active ||
      oldDelegate.progress != progress;
}

/// The phrase line in the banner: a plain label for one phrase, a tappable
/// disclosure for a set.
class _PhraseHeading extends StatelessWidget {
  const _PhraseHeading({
    required this.label,
    required this.onContainer,
    this.expanded,
    this.onToggle,
  });

  final String label;
  final Color onContainer;
  final bool? expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      '\u201c$label\u201d',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: onContainer,
        fontWeight: FontWeight.w600,
      ),
    );

    final isExpanded = expanded;
    if (isExpanded == null || onToggle == null) return text;

    return InkWell(
      onTap: onToggle,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: text),
          Icon(
            isExpanded
                ? Icons.keyboard_arrow_up_rounded
                : Icons.keyboard_arrow_down_rounded,
            size: 18,
            color: onContainer.withValues(alpha: 0.8),
          ),
        ],
      ),
    );
  }
}

/// One phrase and its running count, inside the expanded banner.
class _PhraseCountRow extends StatelessWidget {
  const _PhraseCountRow({
    required this.phrase,
    required this.count,
    required this.onContainer,
    required this.isLatest,
  });

  final String phrase;
  final int count;
  final Color onContainer;

  /// Whether this is the phrase the last count landed on.
  final bool isLatest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            isLatest ? Icons.graphic_eq_rounded : Icons.circle_outlined,
            size: 12,
            color: onContainer.withValues(alpha: isLatest ? 0.95 : 0.45),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              phrase,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: onContainer.withValues(alpha: isLatest ? 1.0 : 0.8),
                fontWeight: isLatest ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: theme.textTheme.bodySmall?.copyWith(
              color: onContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
