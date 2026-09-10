/// A unit of pre-paid streaming time granted by the voice-block service.
///
/// Holding streaming time in blocks is what bounds the operator's exposure:
/// a client-held WebSocket cannot be hung up by the server that authorised
/// it, so the credit is spent up front and only ever one block at a time
/// (design, "Why blocks").
class VoiceBlock {
  const VoiceBlock({
    required this.id,
    required this.deepgramToken,
    required this.blockSeconds,
    required this.expiresAt,
    required this.balanceAfter,
  });

  /// Server-assigned id, and the key every ledger movement for this block is
  /// made under. Reported back on release.
  final String id;

  /// Short-lived Deepgram credential. It authorises *establishing* a
  /// connection; a socket opened with it stays authorised for its lifetime,
  /// which is what makes a 300-second block workable with a 30-second token.
  final String deepgramToken;

  /// How long the block pays for.
  final int blockSeconds;

  /// When the block stops being live, server-side.
  final DateTime expiresAt;

  /// Credit balance after the block was debited.
  final int balanceAfter;

  @override
  String toString() =>
      'VoiceBlock(id: $id, seconds: $blockSeconds, balanceAfter: $balanceAfter)';
}

/// What the service did with a released block.
class BlockRelease {
  const BlockRelease({required this.refunded, this.balance});

  /// True when the server judged the block refundable and credited it back.
  /// The client may *assert* eligibility, but this is the only answer that
  /// counts: the server validates against its own record of the grant time.
  final bool refunded;

  /// Balance after a refund. Null when nothing moved — the server does not
  /// spend a ledger round trip echoing an unchanged number.
  final int? balance;

  @override
  String toString() => 'BlockRelease(refunded: $refunded, balance: $balance)';
}

/// Every way a block request can fail, as a type rather than a status code.
///
/// The transport is an implementation detail of the adapter: no `http`
/// response and no bare `Exception` may reach a caller, because the caller's
/// decision — show the paywall, wait for a stale block to expire, retry, give
/// up — differs per case and must not be made by string-matching an error.
sealed class BlockFailure implements Exception {
  const BlockFailure(this.message);

  /// Human-readable, and safe to show: the UI has no better wording for these
  /// than the reason itself.
  final String message;

  @override
  String toString() => message;
}

/// 401. No Supabase session, or one the function would not accept.
class BlockUnauthenticated extends BlockFailure {
  const BlockUnauthenticated([
    super.message = 'This device is not signed in to the voice service.',
  ]);
}

/// 402. Not enough credit for a block. Carries what the server reported so
/// the paywall can say how far short the user is rather than guessing.
class BlockInsufficientCredit extends BlockFailure {
  const BlockInsufficientCredit({required this.balance, required this.required})
    : super('Not enough voice minutes left.');

  final int balance;
  final int required;

  @override
  String toString() =>
      'BlockInsufficientCredit(balance: $balance, required: $required)';
}

/// 409. Another session of this user's already holds a live block. Recoverable
/// by waiting: [expiresAt] says how long, when the server told us.
class BlockInFlight extends BlockFailure {
  const BlockInFlight({this.expiresAt})
    : super('Another voice session is still running on this account.');

  final DateTime? expiresAt;

  @override
  String toString() => 'BlockInFlight(expiresAt: $expiresAt)';
}

/// 429. Too many grants in the server's window.
class BlockRateLimited extends BlockFailure {
  const BlockRateLimited({this.retryAfter})
    : super('Too many voice sessions started just now. Try again shortly.');

  final Duration? retryAfter;

  @override
  String toString() => 'BlockRateLimited(retryAfter: $retryAfter)';
}

/// 503. RevenueCat or Deepgram would not answer. No credit was spent.
class BlockProviderUnavailable extends BlockFailure {
  const BlockProviderUnavailable([
    super.message = 'The voice service is temporarily unavailable.',
  ]);
}

/// 404. The block is not live any more: unknown, not this caller's, already
/// reconciled, or expired.
///
/// Distinct from [BlockRequestRejected] because the answer is different:
/// there is nothing here to retry, so a session holding this block has to
/// end rather than keep asking.
class BlockNotFound extends BlockFailure {
  const BlockNotFound([super.message = 'This voice block is no longer live.']);
}

/// A request the server refused as malformed or unknown — 400, or any other
/// status with no defined meaning. A client bug, not a user problem.
class BlockRequestRejected extends BlockFailure {
  const BlockRequestRejected({required this.status, required this.reason})
    : super('The voice service refused the request.');

  final int status;
  final String reason;

  @override
  String toString() => 'BlockRequestRejected($status, $reason)';
}

/// The request never produced an answer: offline, DNS, TLS, timeout, or a body
/// that was not the JSON the contract promises.
class BlockUnreachable extends BlockFailure {
  const BlockUnreachable(this.cause)
    : super('Could not reach the voice service.');

  final Object cause;

  @override
  String toString() => 'BlockUnreachable($cause)';
}

/// Port for the credit lifecycle. The one seam through which the app talks to
/// the voice-block Edge Function.
///
/// Declared here, in the domain, so [CountingEngine] can drive acquire,
/// renewal and release without knowing that any of it is HTTP.
abstract class BlockService {
  /// Requests a block for [sessionId].
  ///
  /// The same [sessionId] within a live block is a *renewal* — the server
  /// grants the next block and supersedes the one it replaces. A different
  /// session id while a block is live is a [BlockInFlight].
  ///
  /// Throws a [BlockFailure] and nothing else.
  Future<VoiceBlock> acquire(String sessionId);

  /// Mints a fresh Deepgram credential for a block that is still live.
  ///
  /// A [VoiceBlock.deepgramToken] authorises *establishing* a connection and
  /// lives about 30 seconds, while the block it came with lives 300. A socket
  /// that drops after the first tenth of a block therefore has no credential
  /// to come back on, and asking for a *grant* instead would be worse: the
  /// server reads a matching session id as a renewal and would debit a block
  /// per dropped socket. This never debits.
  ///
  /// Throws a [BlockFailure] and nothing else. [BlockNotFound] means the
  /// block is gone and the session holding it is over.
  Future<String> refreshToken(String blockId);

  /// Reports what a block was used for, and asks for a refund when the client
  /// believes the block delivered nothing.
  ///
  /// [detections] is always sent, honestly: the server treats an absent or
  /// non-integer count as no report at all rather than as zero, so omitting it
  /// forfeits the refund it might otherwise allow.
  ///
  /// Throws a [BlockFailure] and nothing else.
  Future<BlockRelease> release(
    String blockId, {
    required int streamedSecs,
    required int detections,
    required bool eligibleForRefund,
  });

  Future<void> dispose();
}
