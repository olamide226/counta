import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/counting/counting_engine.dart';

/// The header shown while a voice counting session is running.
///
/// Everything here is driven by the active [ColorScheme] so the banner matches
/// whichever theme the user picked, and the stop control is a labelled button
/// rather than a bare icon — ending a session should never be a guess.
class VoiceSessionBanner extends StatelessWidget {
  const VoiceSessionBanner({
    super.key,
    required this.status,
    required this.phrase,
    required this.voiceCount,
    required this.manualCount,
    required this.onStop,
    this.diagnostic,
  });

  final EngineStatus status;
  final String phrase;
  final int voiceCount;
  final int manualCount;
  final VoidCallback onStop;
  final String? diagnostic;

  bool get _isListening => status == EngineStatus.live;

  bool get _isUnhealthy =>
      status == EngineStatus.reconnecting ||
      status == EngineStatus.degraded ||
      status == EngineStatus.error;

  String get _statusLabel => switch (status) {
    EngineStatus.live => 'Listening',
    EngineStatus.connecting => 'Connecting…',
    EngineStatus.reconnecting => 'Reconnecting…',
    EngineStatus.requestingBlock => 'Preparing…',
    EngineStatus.degraded => 'Poor connection',
    EngineStatus.exhausted => 'Out of credit',
    EngineStatus.error => 'Voice counting stopped',
    EngineStatus.idle => 'Paused',
    EngineStatus.permissionDenied => 'Microphone access needed',
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
                        Text(
                          '“$phrase”',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: onContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // A labelled button, so stopping is discoverable at a glance.
                  FilledButton.icon(
                    onPressed: onStop,
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
                  _CountPill(
                    icon: Icons.graphic_eq_rounded,
                    label: '$voiceCount by voice',
                    onContainer: onContainer,
                  ),
                  _CountPill(
                    icon: Icons.touch_app_outlined,
                    label: '$manualCount by tap',
                    onContainer: onContainer,
                  ),
                ],
              ),
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

class _CountPill extends StatelessWidget {
  const _CountPill({
    required this.icon,
    required this.label,
    required this.onContainer,
  });

  final IconData icon;
  final String label;
  final Color onContainer;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: onContainer.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: onContainer.withValues(alpha: 0.8)),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: onContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
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
