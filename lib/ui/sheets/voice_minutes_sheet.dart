import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/counting/block_service.dart';
import '../../domain/purchases/minute_store.dart';
import '../../state/providers/minute_store_provider.dart';
import '../../state/providers/voice_minutes_provider.dart';
import '../widgets/voice_minutes_widgets.dart';
import 'counta_sheet.dart';

/// The one place voice minutes are looked at and added to.
///
/// Minutes are added by buying a pack where the store sells them, or by
/// redeeming a code, which always works. The sheet is the same wherever it
/// is opened from; what differs is what the user was in the middle of, so
/// the caller says what "carry on" is called.
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
  String? _codeError;

  /// Whether the code field is open alongside the packs. With no packs it is
  /// the only way to add minutes, so it is always open then.
  bool _showCode = false;

  String? _selectedPack;
  bool _buying = false;
  String? _buyMessage;
  bool _buyMessageIsError = false;

  /// Minutes just added. Non-null switches to the success view.
  int? _added;

  /// Whether the added minutes have shown on the balance yet.
  bool _addedConfirmed = true;

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
    setState(() => _codeError = null);
  }

  Future<void> _redeem() async {
    final code = _code.text.trim();
    if (code.isEmpty || _redeeming) return;

    setState(() {
      _redeeming = true;
      _codeError = null;
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
      _addedConfirmed = true;
      _codeError = error;
    });
  }

  Future<void> _buy(MinutePack pack) async {
    final store = ref.read(minuteStoreProvider);
    if (store == null || _buying) return;

    final minutes = ref.read(voiceMinutesProvider.notifier);
    final before = ref.read(voiceMinutesProvider).balance;
    setState(() {
      _buying = true;
      _buyMessage = null;
    });

    final outcome = await store.buy(pack);
    final confirmed = outcome is PackPurchased
        ? await minutes.awaitPurchasedMinutes(before: before)
        : false;

    if (!mounted) return;
    setState(() {
      _buying = false;
      switch (outcome) {
        case PackPurchased():
          _added = pack.minutes;
          _addedConfirmed = confirmed;
        case PackPurchaseCancelled():
          break;
        case PackPurchasePending(:final message):
          _buyMessage = message;
          _buyMessageIsError = false;
        case PackPurchaseFailed(:final message):
          _buyMessage = message;
          _buyMessageIsError = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final minutes = ref.watch(voiceMinutesProvider);
    final store = ref.watch(minuteStoreProvider);
    final packs = store == null
        ? const AsyncValue<List<MinutePack>>.data([])
        : ref.watch(minutePacksProvider);
    final onSale = packs.valueOrNull ?? const <MinutePack>[];
    final added = _added;

    // With packs on sale the packs are the point, and the balance is one
    // line above them. Without, the balance is the point.
    final selling = added == null && onSale.isNotEmpty;

    return SingleChildScrollView(
      child: CountaSheetBody(
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
          if (selling) ...[
            _BalanceLine(minutesLeft: minutes.left, checking: _checking),
            const SizedBox(height: 16),
            ..._buildPacks(context, onSale),
          ] else ...[
            const SizedBox(height: 12),
            _BalanceTile(
              minutesLeft: minutes.left,
              checking: _checking,
              highlighted: added != null,
            ),
            const SizedBox(height: 20),
            if (added != null)
              ..._buildSuccess(context, added)
            else ...[
              ..._buildCodeEntry(context),
              const SizedBox(height: 20),
              _InfoNote(
                text: switch (packs) {
                  _ when store == null =>
                    'Minute packs are coming soon. Until then, minutes come '
                        'from codes.',
                  AsyncLoading() => 'Loading minute packs…',
                  AsyncError(:final error) =>
                    '${error is MinuteStoreUnavailable ? error.message : "Minute packs couldn't load right now."} '
                        'You can still use a code.',
                  _ =>
                    "Minute packs couldn't load right now. You can still "
                        'use a code.',
                },
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(widget.dismissLabel),
              ),
            ],
          ],
        ],
      ),
    );
  }

  List<Widget> _buildPacks(BuildContext context, List<MinutePack> packs) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selectedId =
        _selectedPack ??
        // The middle one: a first-timer is rarely served by the smallest or
        // ready to commit to the largest.
        packs[packs.length ~/ 2].productId;
    final selected = packs.firstWhere(
      (pack) => pack.productId == selectedId,
      orElse: () => packs.first,
    );
    final bestValue = _bestValue(packs);
    final message = _buyMessage;

    return [
      for (final pack in packs) ...[
        _PackCard(
          pack: pack,
          selected: pack.productId == selected.productId,
          bestValue: pack.productId == bestValue,
          onTap: _buying
              ? null
              : () => setState(() {
                  _selectedPack = pack.productId;
                  _buyMessage = null;
                }),
        ),
        const SizedBox(height: 10),
      ],
      const SizedBox(height: 6),
      FilledButton(
        onPressed: _buying ? null : () => _buy(selected),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
        child: _buying
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text('Buy ${minutesCount(selected.minutes)}'),
      ),
      if (message != null) ...[
        const SizedBox(height: 10),
        _Message(text: message, isError: _buyMessageIsError),
      ],
      const SizedBox(height: 12),
      Text(
        'Minutes are only used while voice counting is on. Unused ones come '
        'back when you stop early.',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 8),
      if (_showCode) ...[
        const SizedBox(height: 8),
        ..._buildCodeEntry(context),
      ] else
        TextButton(
          onPressed: () => setState(() => _showCode = true),
          child: const Text('Have a code?'),
        ),
      if (_showCode || widget.dismissLabel != 'Done') ...[
        const SizedBox(height: 4),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(widget.dismissLabel),
        ),
      ],
    ];
  }

  /// The pack with the lowest price per minute, when one is strictly lowest.
  /// A label is a claim; with a tie there is nothing true to claim.
  static String? _bestValue(List<MinutePack> packs) {
    if (packs.length < 2) return null;
    final sorted = [...packs]
      ..sort((a, b) => a.pricePerMinute.compareTo(b.pricePerMinute));
    if (sorted[0].pricePerMinute >= sorted[1].pricePerMinute) return null;
    return sorted[0].productId;
  }

  List<Widget> _buildCodeEntry(BuildContext context) {
    final theme = Theme.of(context);
    final error = _codeError;

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
              // Opened by "Have a code?", so the keyboard is wanted, and
              // focusing scrolls the field into view above it.
              autofocus: _showCode,
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
        _Message(text: error, isError: true),
      ],
    ];
  }

  List<Widget> _buildSuccess(BuildContext context, int added) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final resumeLabel = widget.resumeLabel;
    final note = _addedConfirmed
        ? widget.successNote
        : 'They can take a moment to show up.';

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

/// "1 hour", "3 hours 20 minutes": what a pack is worth in practice time.
String packDuration(int minutes) {
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  final parts = [
    if (hours > 0) hours == 1 ? '1 hour' : '$hours hours',
    if (rest > 0 || hours == 0) minutesCount(rest),
  ];
  return '${parts.join(' ')} of voice counting';
}

/// One pack, selectable.
class _PackCard extends StatelessWidget {
  const _PackCard({
    required this.pack,
    required this.selected,
    required this.bestValue,
    required this.onTap,
  });

  final MinutePack pack;
  final bool selected;
  final bool bestValue;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            minutesCount(pack.minutes),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (bestValue)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.tertiaryContainer,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                'Best value',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onTertiaryContainer,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        packDuration(pack.minutes),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  pack.priceLabel,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The balance as one line, above the packs.
class _BalanceLine extends StatelessWidget {
  const _BalanceLine({required this.minutesLeft, required this.checking});

  final int? minutesLeft;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final left = minutesLeft;
    return Text(
      left != null
          ? 'You have ${minutesCount(left)} left'
          : checking
          ? 'Checking your minutes…'
          : "Couldn't check your minutes right now",
      style: theme.textTheme.bodyLarge?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _InfoNote extends StatelessWidget {
  const _InfoNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
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
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.isError});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isError
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.hourglass_top_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
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
