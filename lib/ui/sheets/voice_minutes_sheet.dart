import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/counting/block_service.dart';
import '../../state/providers/voice_minutes_provider.dart';
import '../widgets/voice_minutes_widgets.dart';
import 'counta_sheet.dart';

/// The one place voice minutes are looked at and added to.
///
/// Until minute packs are on sale, adding means redeeming a code. The sheet
/// is the same wherever it is opened from; what differs is what the user was
/// in the middle of, so the caller says what "carry on" is called.
class VoiceMinutesSheet extends ConsumerStatefulWidget {
  const VoiceMinutesSheet({
    super.key,
    this.resumeLabel,
    this.successNote,
    this.dismissLabel = 'Done',
  });

  /// Label for going straight back to voice counting once minutes are added.
  /// Null when there is nothing to go back to, as from Settings.
  final String? resumeLabel;

  /// A reassurance shown under "N minutes added".
  final String? successNote;

  /// Label for leaving without adding anything.
  final String dismissLabel;

  @override
  ConsumerState<VoiceMinutesSheet> createState() => _VoiceMinutesSheetState();
}

class _VoiceMinutesSheetState extends ConsumerState<VoiceMinutesSheet> {
  final _code = TextEditingController();

  bool _checking = true;
  bool _redeeming = false;
  String? _error;

  /// Minutes the code just added. Non-null switches to the success view.
  int? _added;

  @override
  void initState() {
    super.initState();
    _code.addListener(_onCodeChanged);
    // Minutes can be added from outside the app, so what was true at launch
    // is not trusted on the one screen that is about the number.
    ref.read(voiceMinutesProvider.notifier).refresh().whenComplete(() {
      if (mounted) setState(() => _checking = false);
    });
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _onCodeChanged() {
    // An error describes the code that was sent, not the one being typed.
    setState(() => _error = null);
  }

  Future<void> _redeem() async {
    final code = _code.text.trim();
    if (code.isEmpty || _redeeming) return;

    setState(() {
      _redeeming = true;
      _error = null;
    });

    int? added;
    String? error;
    try {
      final outcome = await ref
          .read(voiceMinutesProvider.notifier)
          .redeem(code);
      switch (outcome) {
        case VoucherRedeemed(:final credits):
          added = credits;
        case VoucherAlreadyRedeemed(:final message):
          error = message;
        case VoucherRefused(:final message):
          error = message;
      }
    } on BlockFailure catch (failure) {
      error = failure.message;
    } catch (_) {
      error = "Couldn't check that code. Please try again.";
    }

    if (!mounted) return;
    setState(() {
      _redeeming = false;
      _added = added;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final minutes = ref.watch(voiceMinutesProvider);
    final added = _added;

    return CountaSheetBody(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Voice minutes',
                style: theme.textTheme.headlineSmall,
              ),
            ),
            IconButton(
              onPressed: () => Navigator.of(context).pop(false),
              icon: const Icon(Icons.close_rounded),
              tooltip: 'Close',
            ),
          ],
        ),
        const SizedBox(height: 12),
        _BalanceTile(
          minutesLeft: minutes.left,
          checking: _checking,
          highlighted: added != null,
        ),
        const SizedBox(height: 20),
        if (added != null)
          ..._buildSuccess(context, added)
        else
          ..._buildCodeEntry(context),
      ],
    );
  }

  List<Widget> _buildCodeEntry(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final error = _error;

    return [
      Text(
        'Have a code?',
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _code,
              enabled: !_redeeming,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _redeem(),
              decoration: const InputDecoration(
                hintText: 'Enter your code',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: _code.text.trim().isEmpty || _redeeming ? null : _redeem,
            style: FilledButton.styleFrom(minimumSize: const Size(96, 56)),
            child: _redeeming
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Redeem'),
          ),
        ],
      ),
      if (error != null) ...[
        const SizedBox(height: 10),
        Semantics(
          liveRegion: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline, size: 18, color: scheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  error,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 20),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Minute packs are coming soon. Until then, minutes come from '
                'codes.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(widget.dismissLabel),
      ),
    ];
  }

  List<Widget> _buildSuccess(BuildContext context, int added) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final resumeLabel = widget.resumeLabel;
    final note = widget.successNote;

    return [
      Semantics(
        liveRegion: true,
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: scheme.primary,
              child: Icon(
                Icons.check_rounded,
                size: 20,
                color: scheme.onPrimary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${minutesCount(added)} added',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (note != null)
                    Text(
                      note,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      if (resumeLabel != null) ...[
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(true),
          icon: const Icon(Icons.mic),
          label: Text(resumeLabel),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Done'),
        ),
      ] else
        FilledButton(
          onPressed: () => Navigator.of(context).pop(false),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          child: const Text('Done'),
        ),
    ];
  }
}

/// The balance, as the one big number on the sheet.
class _BalanceTile extends StatelessWidget {
  const _BalanceTile({
    required this.minutesLeft,
    required this.checking,
    required this.highlighted,
  });

  final int? minutesLeft;
  final bool checking;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = highlighted
        ? scheme.onPrimaryContainer
        : scheme.onSurface;
    final left = minutesLeft;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      decoration: BoxDecoration(
        color: highlighted
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          MergeSemantics(
            child: Column(
              children: [
                Text(
                  left?.toString() ?? '–',
                  style: theme.textTheme.displayMedium?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w300,
                  ),
                ),
                Text(
                  left != null
                      ? (left == 1 ? 'minute left' : 'minutes left')
                      : checking
                      ? 'Checking your minutes…'
                      : "Couldn't check your minutes right now",
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'One minute is one minute of voice counting',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: highlighted
                  ? foreground.withValues(alpha: 0.8)
                  : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the voice minutes sheet. Completes with true when the user chose to
/// go straight back to voice counting.
Future<bool?> showVoiceMinutesSheet(
  BuildContext context, {
  String? resumeLabel,
  String? successNote,
  String dismissLabel = 'Done',
}) {
  return showCountaSheet<bool>(
    context: context,
    builder: (_) => VoiceMinutesSheet(
      resumeLabel: resumeLabel,
      successNote: successNote,
      dismissLabel: dismissLabel,
    ),
  );
}
