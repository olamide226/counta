import '../../../domain/counting/block_service.dart';

/// A [BlockService] that reports what passed through it.
///
/// The engine buys and releases blocks; the screens need to show the balance
/// those calls leave behind. Rather than teach the engine about balances — it
/// decides nothing by them — the service it is handed is wrapped, and the
/// wrapper tells an observer what each answer said. The engine sees an
/// ordinary block service and is unchanged.
class ObservedBlockService implements BlockService {
  ObservedBlockService(
    this._inner, {
    required this.onGranted,
    required this.onReleased,
    required this.onInsufficient,
  });

  final BlockService _inner;

  /// A block was bought. [firstOfSession] is false for a renewal.
  final void Function(VoiceBlock block, {required bool firstOfSession})
  onGranted;

  /// A block was handed back, with what it cost and what came back.
  final void Function(BlockRelease release) onReleased;

  /// A block was refused for lack of credit. Carries the server's own numbers,
  /// which are fresher than anything the app had cached.
  final void Function(BlockInsufficientCredit refusal) onInsufficient;

  String? _sessionId;

  @override
  Future<VoiceBlock> acquire(String sessionId) async {
    final VoiceBlock block;
    try {
      block = await _inner.acquire(sessionId);
    } on BlockInsufficientCredit catch (refusal) {
      onInsufficient(refusal);
      rethrow;
    }
    final first = sessionId != _sessionId;
    _sessionId = sessionId;
    onGranted(block, firstOfSession: first);
    return block;
  }

  @override
  Future<String> refreshToken(String blockId) => _inner.refreshToken(blockId);

  @override
  Future<BlockRelease> release(
    String blockId, {
    required int streamedSecs,
    required int detections,
    required bool eligibleForRefund,
  }) async {
    final release = await _inner.release(
      blockId,
      streamedSecs: streamedSecs,
      detections: detections,
      eligibleForRefund: eligibleForRefund,
    );
    onReleased(release);
    return release;
  }

  @override
  Future<VoiceBalance> readBalance() => _inner.readBalance();

  @override
  Future<VoucherOutcome> redeem(String code) => _inner.redeem(code);

  /// The wrapped service is shared and outlives any one engine, so this does
  /// not dispose it.
  @override
  Future<void> dispose() async {}
}
