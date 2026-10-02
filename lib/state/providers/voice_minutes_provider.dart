import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/counting/block_service.dart';
import 'supabase_providers.dart';

/// What the session that just ended cost.
@immutable
class VoiceUsage {
  const VoiceUsage({required this.used, required this.returned, this.left});

  /// Minutes the session was charged for.
  final int used;

  /// Unused minutes that came back when it stopped.
  final int returned;

  /// Minutes left afterwards, when known.
  final int? left;
}

Future<void> _delay(Duration duration) => Future.delayed(duration);

/// Everything the screens know about the user's voice minutes.
///
/// One minute of voice counting is one credit on the server; the screens only
/// ever say "minutes".
@immutable
class VoiceMinutes {
  const VoiceMinutes({
    this.available = false,
    this.balance,
    this.required = 5,
    this.paidUntil,
    this.sessionStart,
    this.lastUsage,
    this.asOf,
    this.consumed = 0,
  });

  /// Whether this build has a voice service at all. False in a dev build that
  /// streams on a developer key, where there are no minutes to show.
  final bool available;

  /// Minutes not yet spent. Null until the first answer arrives.
  final int? balance;

  /// Minutes a session needs before it can start.
  final int required;

  /// When the block already paid for runs out. Null between sessions.
  final DateTime? paidUntil;

  /// Minutes the user had when the running session began.
  final int? sessionStart;

  /// What the last session cost. Cleared when the next one starts.
  final VoiceUsage? lastUsage;

  /// The moment [left] is measured at. Advanced by a timer during a session
  /// so the number counts down without anything else happening.
  final DateTime? asOf;

  /// Minutes charged since the app launched, net of what came back. Only
  /// ever read as a difference: the session controller measures a counting
  /// session's share of it for the saved record.
  final int consumed;

  /// Minutes of voice counting left, including what remains of the block
  /// already paid for. Null when the balance is not known.
  int? get left {
    final balance = this.balance;
    if (balance == null) return null;
    final paid = paidUntil;
    final now = asOf;
    if (paid == null || now == null) return balance;
    final seconds = paid.difference(now).inSeconds;
    return balance + max(0, (seconds / 60).ceil());
  }

  /// Whether a session could start. Unknown counts as yes: the server is the
  /// one that decides, and a balance that has not loaded yet must not stand
  /// between someone and their practice.
  bool get canStart {
    final balance = this.balance;
    return balance == null || balance >= required;
  }

  /// Whether to warn that minutes are running out (requirement 4.4): at or
  /// below a fifth of what the session started with, or three minutes,
  /// whichever is more.
  bool get isLow {
    final left = this.left;
    if (left == null) return false;
    final start = sessionStart ?? 0;
    return left <= max(3, (start * 0.2).ceil());
  }

  VoiceMinutes copyWith({
    bool? available,
    int? balance,
    int? required,
    DateTime? paidUntil,
    bool clearPaidUntil = false,
    int? sessionStart,
    VoiceUsage? lastUsage,
    bool clearLastUsage = false,
    DateTime? asOf,
    int? consumed,
  }) {
    return VoiceMinutes(
      available: available ?? this.available,
      balance: balance ?? this.balance,
      required: required ?? this.required,
      paidUntil: clearPaidUntil ? null : paidUntil ?? this.paidUntil,
      sessionStart: sessionStart ?? this.sessionStart,
      lastUsage: clearLastUsage ? null : lastUsage ?? this.lastUsage,
      asOf: asOf ?? this.asOf,
      consumed: consumed ?? this.consumed,
    );
  }
}

/// Keeps [VoiceMinutes] in step with the voice service.
///
/// Fed from three directions: a read when the app asks, the answers the
/// engine's block calls come back with (through `ObservedBlockService`), and
/// the result of redeeming a code. None of them is trusted over the others —
/// each simply carries the newest balance the server has stated.
class VoiceMinutesNotifier extends StateNotifier<VoiceMinutes> {
  VoiceMinutesNotifier(
    this._service, {
    DateTime Function() now = DateTime.now,
    this.tick = const Duration(seconds: 15),
    Future<void> Function(Duration) pause = _delay,
  }) : _now = now,
       _pause = pause,
       super(VoiceMinutes(available: _service != null));

  final BlockService? _service;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _pause;

  /// How often the countdown is refreshed while a block is running.
  final Duration tick;

  Timer? _ticker;

  /// Credits bought and returned by the running session, across renewals.
  int _spent = 0;
  int _returned = 0;

  /// What earlier sessions since launch cost, already settled.
  int _settled = 0;

  int get _sessionCost => max(0, _spent - _returned);

  /// Asks the server for the balance. Failures are left alone: an old number
  /// on screen is better than an error for something nobody asked to do.
  Future<void> refresh() async {
    final service = _service;
    if (service == null) return;
    try {
      final answer = await service.readBalance();
      if (!mounted) return;
      state = state.copyWith(
        balance: answer.balance,
        required: answer.required,
        asOf: _now(),
      );
    } on BlockFailure catch (failure) {
      debugPrint('Voice minutes not refreshed: $failure');
    }
  }

  /// A block was bought. Called by the observed block service.
  void onGranted(VoiceBlock block, {required bool firstOfSession}) {
    if (!mounted) return;
    if (firstOfSession) {
      _settled += _sessionCost;
      _spent = 0;
      _returned = 0;
    }
    _spent += state.required;
    state = state.copyWith(
      consumed: _settled + _sessionCost,
      balance: block.balanceAfter,
      paidUntil: block.expiresAt,
      // What they had the moment before this session's first block.
      sessionStart: firstOfSession
          ? block.balanceAfter + state.required
          : state.sessionStart,
      clearLastUsage: true,
      asOf: _now(),
    );
    _ticker ??= Timer.periodic(tick, (_) {
      if (mounted) state = state.copyWith(asOf: _now());
    });
  }

  /// A block was handed back.
  void onReleased(BlockRelease release) {
    if (!mounted) return;
    _stopTicker();
    _returned += release.refundedCredits ?? 0;
    final balance = release.balance ?? state.balance;
    state = state.copyWith(
      balance: balance,
      clearPaidUntil: true,
      consumed: _settled + _sessionCost,
      lastUsage: VoiceUsage(
        used: _sessionCost,
        returned: _returned,
        left: balance,
      ),
      asOf: _now(),
    );
    // A release that did not report a balance leaves it one block stale.
    if (release.balance == null) unawaited(refresh());
  }

  /// A block was refused for lack of credit: the server's numbers are the
  /// freshest there are.
  void onInsufficient(BlockInsufficientCredit refusal) {
    if (!mounted) return;
    state = state.copyWith(
      balance: refusal.balance,
      required: refusal.required > 0 ? refusal.required : state.required,
      asOf: _now(),
    );
  }

  /// Dismisses the "used 1 minute" line.
  void clearLastUsage() {
    if (mounted) state = state.copyWith(clearLastUsage: true);
  }

  /// Redeems a code and takes the balance it reports.
  Future<VoucherOutcome> redeem(String code) async {
    final service = _service;
    if (service == null) {
      throw const BlockProviderUnavailable();
    }
    final outcome = await service.redeem(code);
    final balance = switch (outcome) {
      VoucherRedeemed(:final balance) => balance,
      VoucherAlreadyRedeemed(:final balance) => balance,
      VoucherRefused() => null,
    };
    if (!mounted) return outcome;
    if (balance != null) {
      state = state.copyWith(balance: balance, asOf: _now());
    } else if (outcome is! VoucherRefused) {
      unawaited(refresh());
    }
    return outcome;
  }

  /// After a pack is bought, reads the balance until it shows the purchase.
  ///
  /// The store's server credits the minutes, not the app, and the app only
  /// learns of it by asking. Usually the first read has it. Returns false if
  /// it still had not shown after [attempts], which is a delay, not a lost
  /// purchase: the minutes land on the account either way.
  Future<bool> awaitPurchasedMinutes({
    required int? before,
    int attempts = 5,
    Duration gap = const Duration(milliseconds: 1500),
  }) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0) await _pause(gap);
      if (!mounted) return false;
      await refresh();
      final balance = state.balance;
      if (balance != null && (before == null || balance > before)) {
        return true;
      }
    }
    return false;
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void dispose() {
    _stopTicker();
    super.dispose();
  }
}

/// The user's voice minutes, for every screen that shows or spends them.
final voiceMinutesProvider =
    StateNotifierProvider<VoiceMinutesNotifier, VoiceMinutes>((ref) {
      final notifier = VoiceMinutesNotifier(ref.watch(blockServiceProvider));
      // The first read waits for sign-in: before it there is no user to have
      // a balance, and asking would only earn a 401.
      ref.listen(supabaseSessionProvider, (_, next) {
        if (next.hasValue && next.value != null) unawaited(notifier.refresh());
      }, fireImmediately: true);
      return notifier;
    });
