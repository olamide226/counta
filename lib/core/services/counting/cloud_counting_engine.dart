import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'audio_source.dart';
import 'deepgram_socket.dart';
import '../../../domain/counting/block_service.dart';
import '../../../domain/counting/counting_engine.dart';
import '../../../domain/counting/phrase_matcher.dart';
import '../../../domain/counting/speech_socket.dart';
import '../../../domain/counting/transcript_segment.dart';

/// Supplies the credential for the next Deepgram connection.
///
/// The dev-build path only: a developer key, used when no [BlockService] is
/// wired in. Production credentials are short-lived grants that arrive with a
/// block, and the engine never holds a Deepgram master key itself.
typedef DeepgramTokenProvider = Future<String> Function();

/// Builds a speech socket. A block renewal needs two at once, so the engine
/// makes them rather than holding one for the life of the session.
typedef SpeechSocketFactory = SpeechSocket Function();

/// One Deepgram connection and everything the engine tracks about it.
///
/// A *connection*, not a socket: reconnecting an existing socket starts a
/// fresh audio timeline at the provider, which for the matcher is a new
/// stream with a new place on the session timeline.
class _Connection {
  _Connection(this.socket, this.streamId);

  final SpeechSocket socket;

  /// Identifies this connection's transcript stream to the matcher.
  String streamId;

  /// Session byte offset of the first audio frame handed to this connection,
  /// which is exactly where its timeline sits on the session's. Null until it
  /// has been given a frame, and therefore until it can be positioned at all.
  int? firstFrameByte;

  StreamSubscription<TranscriptSegment>? segments;
  StreamSubscription<SocketState>? state;
  StreamSubscription<void>? activity;

  void detach() {
    cancelQuietly(segments);
    cancelQuietly(state);
    cancelQuietly(activity);
    segments = null;
    state = null;
    activity = null;
  }
}

/// Cancels a subscription without waiting for the future it returns.
///
/// Delivery stops the moment `cancel()` is called; the future reports the
/// *source's* teardown, which for the controller-backed streams here is
/// nothing at all. Awaiting it makes teardown depend on a source that may
/// never answer — and under `fake_async` it never completes at all, which
/// would leave the engine's own timing untestable.
void cancelQuietly(StreamSubscription<Object?>? subscription) {
  subscription?.cancel().catchError((Object _) {});
}

/// Concrete implementation of [CountingEngine] using cloud streaming STT
/// (Deepgram/SpeechSocket), [AudioSource] PCM capture, local [PhraseMatcher],
/// and pre-paid blocks from [BlockService].
class CloudCountingEngine implements CountingEngine {
  final AudioSource _audioSource;
  final SpeechSocketFactory _socketFactory;
  final MatcherConfig matcherConfig;

  /// Dev-build credential source. Null in production, where [blockService]
  /// supplies the token as part of a block.
  final DeepgramTokenProvider? tokenProvider;

  /// Buys streaming time. Null in a dev build using [tokenProvider], in which
  /// case nothing is billed, nothing renews and nothing is released.
  final BlockService? blockService;

  /// Fraction of a block at which the next one is requested (requirement 3.9).
  final double renewalFraction;

  /// How long both connections stream the same audio at a renewal seam.
  ///
  /// The incoming connection is confirmed open before the outgoing one is
  /// closed, and gets real speech through it before it has to carry the
  /// session alone. Both transcribe this window; the matcher counts it once.
  final Duration renewalOverlap;

  /// Delay before retrying a renewal that failed for a reason other than
  /// credit. Bounded by the current block's own expiry.
  final Duration renewalRetryDelay;

  /// Server-side refund window (requirement 3.11). Used only to decide what
  /// the client *asserts*; the server validates against its own grant time.
  final Duration refundWindow;

  /// Cap on the end-of-session usage report. Ending a session is the user's
  /// action and must not hang on the network.
  final Duration releaseTimeout;

  /// How long the engine keeps trying to restore a dropped session before it
  /// gives up and reports [EngineStatus.error].
  ///
  /// Sized for the real use case: sessions run 1–2 hours, so a drop must
  /// survive a tunnel, a lift, or a Wi-Fi-to-cellular handover. Retrying for
  /// minutes costs nothing while idle and is the difference between losing a
  /// blip and losing the session.
  final Duration reconnectWindow;

  /// Ceiling on the exponential backoff between attempts.
  final Duration maxReconnectBackoff;

  /// Maximum time audio may flow without any response from the transcription
  /// service before the socket is treated as silently dead.
  final Duration transcriptionSilenceTimeout;

  /// How often the silent-connection watchdog checks the latest activity.
  final Duration transcriptionWatchdogInterval;

  final StreamController<CountEvent> _countsController =
      StreamController<CountEvent>.broadcast();
  final StreamController<EngineStatus> _statusController =
      StreamController<EngineStatus>.broadcast();
  final StreamController<String> _diagnosticsController =
      StreamController<String>.broadcast();

  StreamSubscription<Uint8List>? _audioSubscription;

  /// The connection currently carrying the session, and the incoming one
  /// during a renewal seam.
  _Connection? _primary;
  _Connection? _pending;

  /// Every socket this engine is responsible for closing.
  final Set<SpeechSocket> _ownedSockets = {};

  /// False when the engine was handed a single socket instance rather than a
  /// factory, which makes an overlapping renewal impossible.
  final bool _canRenew;

  PhraseMatcher? _matcher;
  PhraseSpec? _phrase;
  EngineStatus _status = EngineStatus.idle;
  int _seq = 0;
  int _voiceCount = 0;
  int _manualCount = 0;
  DateTime? _startTime;

  /// Identifies this session to the block service. The server reads a grant
  /// carrying a live block's session id as that session renewing itself, and
  /// any other session id as a conflict.
  String? _sessionId;

  VoiceBlock? _block;

  /// A block that has been paid for but whose socket has not connected yet.
  /// Held so a failed connect retries with the block already bought instead of
  /// buying another.
  VoiceBlock? _pendingBlock;

  DateTime? _blockGrantedAt;
  int _detectionsThisBlock = 0;
  int _blocksUsed = 0;

  /// Set when a renewal was refused for lack of credit. The current block runs
  /// to completion regardless (requirement 3.10); this is what the engine
  /// reports when it does.
  bool _outOfCredit = false;
  bool _renewalInFlight = false;

  Timer? _renewalTimer;
  Timer? _blockExpiryTimer;
  Timer? _overlapTimer;

  /// True once the session's streaming is over — stopped by the user, or
  /// ended by exhaustion — so late socket and audio callbacks do not schedule
  /// a reconnect for a session that is finished.
  bool _stopped = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  Timer? _transcriptionWatchdog;
  DateTime? _lastSocketActivityAt;
  DateTime? _lastAudioFrameAt;

  /// Completes once capture is confirmed working — first frame in — or fails
  /// when the microphone refuses. Gates the socket: nothing is connected until
  /// audio is known to flow.
  Completer<bool>? _captureConfirmed;

  /// Frames captured before the socket finished its first connect. Capture now
  /// starts first, so without this the opening moments of every session — and
  /// any repetition in them — went on the floor.
  final List<Uint8List> _preConnectFrames = [];
  bool _awaitingFirstConnect = true;

  /// Roughly ten seconds at 16 kHz / 20 ms frames. A connect that takes longer
  /// than this has bigger problems than a gap in the audio.
  static const int _maxPreConnectFrames = 500;

  /// 16 kHz mono PCM16, as [AudioSource.recordConfig] captures it. Byte count
  /// is the session's audio clock: it is what the provider timestamps against,
  /// so it maps a connection's timeline onto the session's exactly, with no
  /// wall clock involved.
  static const int _bytesPerSecond = 16000 * 2;

  /// Total audio captured this session, in bytes.
  int _capturedBytes = 0;

  /// Names each connection's transcript stream uniquely within a session.
  int _streamSeq = 0;

  /// True while a reconnect attempt is executing. The attempt closes the old
  /// socket first, which emits `disconnected` — without this guard the engine
  /// would read its own teardown as a fresh drop and stack another reconnect
  /// on top of the one already running.
  bool _reconnectInFlight = false;
  final math.Random _random = math.Random();

  /// When the current run of failures began. Null while healthy — the retry
  /// budget is measured from here, and resets on every successful reconnect.
  DateTime? _recoveringSince;

  /// Total reconnects across the session, for the end-of-session summary.
  int _totalReconnects = 0;

  /// Cumulative time spent disconnected, so a long session can report how much
  /// audio went uncounted rather than silently under-counting.
  Duration _downtime = Duration.zero;

  int get totalReconnects => _totalReconnects;
  Duration get downtime => _downtime;

  /// Blocks bought this session, including the first.
  int get blocksUsed => _blocksUsed;

  /// The block currently paying for streaming, or null in dev-token mode and
  /// once the session has been released.
  VoiceBlock? get currentBlock => _block;

  String? get sessionId => _sessionId;

  CloudCountingEngine({
    this.tokenProvider,
    this.blockService,
    AudioSource? audioSource,
    SpeechSocket? speechSocket,
    SpeechSocketFactory? socketFactory,
    this.matcherConfig = const MatcherConfig(),
    this.renewalFraction = 0.9,
    this.renewalOverlap = const Duration(seconds: 3),
    this.renewalRetryDelay = const Duration(seconds: 10),
    this.refundWindow = const Duration(seconds: 30),
    this.releaseTimeout = const Duration(seconds: 3),
    this.reconnectWindow = const Duration(minutes: 5),
    this.maxReconnectBackoff = const Duration(seconds: 15),
    this.transcriptionSilenceTimeout = const Duration(seconds: 20),
    this.transcriptionWatchdogInterval = const Duration(seconds: 5),
  }) : assert(
         tokenProvider != null || blockService != null,
         'A voice session needs a credential source: a block service in '
         'production, or a token provider in a dev build.',
       ),
       _audioSource = audioSource ?? AudioSource(),
       // A single injected socket cannot overlap with itself, so a session
       // built that way never renews. Production passes neither and gets the
       // real factory.
       _canRenew = socketFactory != null || speechSocket == null,
       _socketFactory =
           socketFactory ??
           (speechSocket != null ? (() => speechSocket) : DeepgramSocket.new) {
    if (speechSocket != null) _ownedSockets.add(speechSocket);
  }

  @override
  Stream<CountEvent> get counts => _countsController.stream;

  @override
  Stream<EngineStatus> get status => _statusController.stream;

  @override
  Stream<String> get diagnostics => _diagnosticsController.stream;

  EngineStatus get currentStatus => _status;
  PhraseSpec? get phrase => _phrase;
  int get voiceCount => _voiceCount;
  int get manualCount => _manualCount;
  int get totalCount => _voiceCount + _manualCount;

  void _setStatus(EngineStatus newStatus) {
    _status = newStatus;
    if (!_statusController.isClosed) {
      _statusController.add(_status);
    }
  }

  void _report(String message) {
    if (!_diagnosticsController.isClosed) {
      _diagnosticsController.add(message);
    }
  }

  @override
  Future<void> start([PhraseSpec? phrase]) async {
    final targetPhrase =
        phrase ??
        const PhraseSpec(
          raw: "I'm rich in wisdom",
          normalisedTokens: ['i', 'am', 'rich', 'in', 'wisdom'],
        );

    _seq = 0;
    _voiceCount = 0;
    _manualCount = 0;
    _stopped = false;
    _reconnectAttempts = 0;
    _recoveringSince = null;
    _totalReconnects = 0;
    _downtime = Duration.zero;
    _lastSocketActivityAt = null;
    _lastAudioFrameAt = null;
    _preConnectFrames.clear();
    _awaitingFirstConnect = true;
    _capturedBytes = 0;
    _streamSeq = 0;
    _block = null;
    _pendingBlock = null;
    _blockGrantedAt = null;
    _detectionsThisBlock = 0;
    _blocksUsed = 0;
    _outOfCredit = false;
    _renewalInFlight = false;
    _sessionId = const Uuid().v4();
    _startTime = DateTime.now();
    _phrase = targetPhrase;
    _matcher = PhraseMatcher(target: targetPhrase, config: matcherConfig);

    _setStatus(EngineStatus.connecting);

    // Capture first, credential second, socket third. The microphone is the
    // thing the user can refuse, and buying streaming time for a session that
    // can never deliver audio spends money on nothing (requirement 2.2).
    // `AudioSource` owns the permission decision and reports a refusal on its
    // error channel, so the engine no longer asks a second time — that second
    // question raced the first and could answer for a different moment.
    if (!await _startConfirmedCapture()) return;
    if (_stopped) return;

    // Tears the whole session down itself before it throws; the caller still
    // gets the reason.
    final token = await _acquireStartCredential();

    // The session can end while the grant is in flight — a microphone stall
    // during the round trip is enough. Opening a socket on it would stream
    // audio nobody is listening to and leave a renewal timer armed.
    if (_stopped) {
      await _releaseBlock();
      return;
    }

    try {
      await _connect(token, asPrimary: true);
    } catch (e) {
      // Every terminal failure goes through the one teardown. Reporting the
      // status and letting go of the microphone was not enough: the renewal
      // timer `_adoptBlock` armed stayed armed, and bought a block every few
      // minutes for the life of the app with nothing attached to it.
      await _endStreaming(
        EngineStatus.error,
        'Could not start voice session: $e',
      );
      rethrow;
    }
  }

  /// Buys the session's first block, or falls back to the dev token.
  ///
  /// Requirement 3.1: no Deepgram connection is opened before a block is
  /// granted, so this sits between confirmed capture and the first connect.
  Future<String> _acquireStartCredential() async {
    final service = blockService;
    if (service == null) {
      try {
        return await tokenProvider!();
      } on VoiceUnavailable catch (e) {
        // Not a failed session — a build that can never start one. Report it
        // as state so the UI can explain it; rethrowing as well lets the
        // caller that opened the session keep its sheet open and show why.
        await _endStreaming(EngineStatus.notConfigured, e.message);
        rethrow;
      } catch (e) {
        await _endStreaming(
          EngineStatus.error,
          'Could not start voice session: $e',
        );
        rethrow;
      }
    }

    _setStatus(EngineStatus.requestingBlock);
    try {
      final block = await service.acquire(_sessionId!);
      _adoptBlock(block);
      return block.deepgramToken;
    } on BlockInsufficientCredit catch (e) {
      // The paywall's cue. Nothing was debited and no socket was opened.
      await _endStreaming(
        EngineStatus.exhausted,
        'Out of voice minutes: ${e.balance} left, and a session needs '
        '${e.required}.',
      );
      rethrow;
    } on BlockFailure catch (e) {
      await _endStreaming(EngineStatus.error, e.message);
      rethrow;
    }
  }

  /// Opens a connection, binds its streams, and returns it.
  ///
  /// Listeners are attached before [SpeechSocket.connect] so the `connected`
  /// transition — which flushes buffered audio and starts the watchdog — is
  /// never missed.
  Future<_Connection> _connect(String token, {required bool asPrimary}) async {
    final socket = asPrimary && _primary != null
        ? _primary!.socket
        : _socketFactory();
    _ownedSockets.add(socket);

    final connection = _Connection(socket, 'stream-${_streamSeq++}');
    _bind(connection);
    if (asPrimary) {
      _primary = connection;
    } else {
      _pending = connection;
    }

    try {
      await socket.connect(apiKeyOrToken: token, phrase: _phrase);
    } catch (e) {
      if (asPrimary) {
        _primary = null;
      } else {
        _pending = null;
      }
      connection.detach();
      rethrow;
    }
    return connection;
  }

  void _bind(_Connection connection) {
    connection.state = connection.socket.state.listen((socketState) {
      // Only the connection carrying the session drives engine state. A
      // pending renewal's transitions are the renewal's business, and a
      // retired connection's close is the engine's own teardown.
      if (!identical(connection, _primary)) return;

      switch (socketState) {
        case SocketState.connecting:
          _setStatus(EngineStatus.connecting);
          break;
        case SocketState.connected:
          _flushPreConnectFrames();
          // Recovered: bank the downtime and reset the retry budget so the
          // next unrelated drop hours later gets a full window of its own.
          final since = _recoveringSince;
          if (since != null) {
            _downtime += DateTime.now().difference(since);
            _recoveringSince = null;
            _report('Voice counting reconnected.');
          }
          _reconnectAttempts = 0;
          _lastSocketActivityAt = DateTime.now();
          _startTranscriptionWatchdog();
          _setStatus(EngineStatus.live);
          break;
        case SocketState.closing:
          break;
        case SocketState.disconnected:
          _stopTranscriptionWatchdog();
          // A disconnect we did not ask for means the session died mid-count.
          // Reporting `idle` here (as this used to) made the UI quietly drop
          // out of voice mode with no explanation.
          if (!_stopped) {
            _report(
              connection.socket.closeDescription ??
                  'Transcription connection closed unexpectedly.',
            );
            _scheduleReconnect(restartAudio: false);
          }
          break;
        case SocketState.error:
          _stopTranscriptionWatchdog();
          if (!_stopped) {
            _report(
              connection.socket.closeDescription ??
                  'Transcription connection errored.',
            );
            _scheduleReconnect(restartAudio: false);
          }
          break;
      }
    });

    connection.activity = connection.socket.activity.listen((_) {
      if (identical(connection, _primary)) {
        _lastSocketActivityAt = DateTime.now();
      }
    });

    connection.segments = connection.socket.segments.listen((segment) {
      final matcher = _matcher;
      if (matcher == null) return;
      // A connection that has not been given a frame has no place on the
      // session timeline, so nothing it says can be positioned on it.
      if (connection.firstFrameByte == null) return;
      for (final detection in matcher.ingest(
        segment,
        streamId: connection.streamId,
      )) {
        _handleDetection(detection);
      }
    });
  }

  // --- Block lifecycle -----------------------------------------------------

  void _adoptBlock(VoiceBlock block) {
    _block = block;
    _blockGrantedAt = DateTime.now();
    _detectionsThisBlock = 0;
    _blocksUsed++;
    _scheduleRenewal(block);
  }

  void _scheduleRenewal(VoiceBlock block) {
    _renewalTimer?.cancel();
    _blockExpiryTimer?.cancel();
    _renewalTimer = null;
    _blockExpiryTimer = null;

    if (_stopped || blockService == null || block.blockSeconds <= 0) return;
    if (!_canRenew) {
      _report('Voice counting cannot renew its streaming time in this build.');
      return;
    }

    final totalMs = block.blockSeconds * 1000;
    // 3.9: renew at 90% of the block, leaving the remaining tenth to open and
    // confirm the next connection before the paid time runs out.
    _renewalTimer = Timer(
      Duration(milliseconds: (totalMs * renewalFraction).round()),
      _renewBlock,
    );
    _blockExpiryTimer = Timer(
      Duration(milliseconds: totalMs),
      () => _onBlockExpired(block),
    );
  }

  Future<void> _renewBlock() async {
    final service = blockService;
    final sessionId = _sessionId;
    if (_stopped || service == null || sessionId == null) return;
    if (_renewalInFlight || _outOfCredit) return;

    _renewalInFlight = true;
    try {
      // The same session id is what tells the server this is a renewal rather
      // than a second concurrent session, so it grants and supersedes instead
      // of answering 409.
      final block = _pendingBlock ??= await service.acquire(sessionId);
      if (_stopped) {
        // The teardown that set `_stopped` released whatever was live before
        // this grant landed, so this one has to hand itself back.
        await _releaseBlock();
        return;
      }

      final next = await _connect(block.deepgramToken, asPrimary: false);
      _pendingBlock = null;
      _adoptBlock(block);
      _startOverlap(next);
    } on BlockInsufficientCredit catch (e) {
      // 3.10: the block already paid for is not cut short. The session keeps
      // counting until it runs out, and only then does it stop.
      _outOfCredit = true;
      _report(
        'Voice minutes have run out (${e.balance} left). Counting continues '
        'until this block ends.',
      );
    } on BlockFailure catch (e) {
      _report('Could not renew voice counting: ${e.message}');
      _retryRenewalLater();
    } catch (e) {
      // The block is bought and held in _pendingBlock; only the socket failed.
      _report('Could not renew voice counting: $e');
      _retryRenewalLater();
    } finally {
      _renewalInFlight = false;
    }
  }

  void _retryRenewalLater() {
    if (_stopped) return;
    _renewalTimer?.cancel();
    _renewalTimer = Timer(renewalRetryDelay, _renewBlock);
  }

  /// Runs both connections over the same audio for [renewalOverlap], then
  /// retires the outgoing one. The matcher counts the duplicated span once.
  void _startOverlap(_Connection next) {
    _overlapTimer?.cancel();
    if (renewalOverlap <= Duration.zero) {
      unawaited(_retireOutgoing(next));
      return;
    }
    _overlapTimer = Timer(renewalOverlap, () {
      _overlapTimer = null;
      unawaited(_retireOutgoing(next));
    });
  }

  Future<void> _retireOutgoing(_Connection next) async {
    if (!identical(_pending, next)) return;
    final outgoing = _primary;
    _pending = null;
    _primary = next;

    // The incoming connection inherits the session: it must be the one the
    // silent-connection watchdog is watching.
    _lastSocketActivityAt = DateTime.now();
    _startTranscriptionWatchdog();

    if (outgoing == null || identical(outgoing, next)) return;
    try {
      // Drained, not dropped: its trailing finals still reach the matcher, on
      // its own stream, and duplicate audio is deduplicated there.
      await outgoing.socket.closeGracefully();
    } catch (e) {
      _report('A retired voice connection did not close cleanly: $e');
    }
    outgoing.detach();
    _matcher?.closeStream(outgoing.streamId);
    _ownedSockets.remove(outgoing.socket);
    await outgoing.socket.dispose();
  }

  void _onBlockExpired(VoiceBlock block) {
    if (_stopped || !identical(_block, block)) return;
    // Nothing succeeded it before the paid time ran out. Streaming past that
    // would be using time nobody paid for.
    unawaited(
      _outOfCredit
          ? _endStreaming(
              EngineStatus.exhausted,
              'Voice minutes have run out. Your count is safe — keep tapping, '
              'or add minutes to carry on.',
            )
          : _endStreaming(
              EngineStatus.degraded,
              'Voice counting paused: the app could not renew its streaming '
              'time. Your count is safe and tapping still works.',
            ),
    );
  }

  /// Ends streaming without ending the session: the count stands, the tap
  /// counter stays live, and the user decides what happens next.
  Future<void> _endStreaming(EngineStatus status, String reason) async {
    if (_stopped) return;
    _stopped = true;
    _report(reason);
    _cancelTimers();
    await _abandonCapture();
    await _closeConnections();
    // Status before the release: the UI must leave voice mode the moment
    // streaming stops, not a network round trip later.
    _setStatus(status);
    await _releaseBlock();
  }

  /// Reports what every block this session is holding was used for, and asks
  /// for the refund of requirement 3.11 for the ones that delivered nothing.
  Future<void> _releaseBlock() async {
    final service = blockService;
    if (service == null) return;

    final block = _block;
    final grantedAt = _blockGrantedAt;
    final detections = _detectionsThisBlock;
    _block = null;
    _blockGrantedAt = null;
    _detectionsThisBlock = 0;

    // A renewal that bought a block and then could not connect it holds one
    // too, and that block is the live one server-side. Left unreported it
    // refuses the user's next session with a 409 for its full duration and is
    // never reclaimed, so it goes back with the honest zeroes it earned.
    final pending = _pendingBlock;
    _pendingBlock = null;

    if (block != null) {
      await _reportUsage(
        service,
        block,
        streamedSecs: grantedAt == null
            ? 0
            : DateTime.now().difference(grantedAt).inSeconds,
        detections: detections,
      );
    }
    if (pending != null) {
      await _reportUsage(service, pending, streamedSecs: 0, detections: 0);
    }
  }

  Future<void> _reportUsage(
    BlockService service,
    VoiceBlock block, {
    required int streamedSecs,
    required int detections,
  }) async {
    try {
      final release = await service
          .release(
            block.id,
            streamedSecs: streamedSecs,
            detections: detections,
            // Asserted, never decided: the server validates this against its
            // own record of the grant time, and an honest detection count is
            // what makes the assertion worth making.
            eligibleForRefund:
                detections == 0 && streamedSecs <= refundWindow.inSeconds,
          )
          .timeout(releaseTimeout);
      if (release.refunded) {
        _report(
          'That block was too short to charge for; your minutes are back.',
        );
      }
    } catch (_) {
      // Best effort by design (requirement 15.3): a block nobody reported on
      // is left unreconciled server-side. Ending a session must not wait on a
      // network that is not there — which, offline, is exactly when it fails.
    }
  }

  void _cancelTimers() {
    _renewalTimer?.cancel();
    _renewalTimer = null;
    _blockExpiryTimer?.cancel();
    _blockExpiryTimer = null;
    _overlapTimer?.cancel();
    _overlapTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopTranscriptionWatchdog();
  }

  Future<void> _closeConnections() async {
    final connections = [_primary, _pending].whereType<_Connection>().toList();
    _primary = null;
    _pending = null;
    for (final connection in connections) {
      try {
        await connection.socket.closeGracefully();
      } catch (e) {
        _report('Voice session did not shut down cleanly: $e');
      }
      connection.detach();
    }
  }

  // --- Capture -------------------------------------------------------------

  /// Releases the microphone after a start that got past capture but failed
  /// before the session was live. Capture runs before the socket exists, so
  /// every failure from that point on has to hand it back explicitly.
  Future<void> _abandonCapture() async {
    cancelQuietly(_audioSubscription);
    _audioSubscription = null;
    await _audioSource.stop();
  }

  /// Starts capture and waits for it to prove itself, before any socket
  /// exists. Returns false when the microphone refused or failed, having
  /// already reported the matching status.
  Future<bool> _startConfirmedCapture() async {
    final confirmation = Completer<bool>();
    _captureConfirmed = confirmation;
    _attachAudio();

    final started = await confirmation.future;
    _captureConfirmed = null;
    if (started) return true;

    // Nothing was connected, so there is nothing to unwind but capture.
    await _abandonCapture();
    return false;
  }

  void _flushPreConnectFrames() {
    if (!_awaitingFirstConnect) return;
    final primary = _primary;
    if (primary == null) return;
    _awaitingFirstConnect = false;

    // The buffer starts at the first captured frame, so its first byte is the
    // session's byte zero. (Overflow drops the newest frames, which leaves a
    // gap in the middle of the flush — only reachable on a connect that takes
    // more than ten seconds.)
    var byte = 0;
    for (final frame in _preConnectFrames) {
      _sendFrame(primary, frame, byte);
      byte += frame.lengthInBytes;
    }
    _preConnectFrames.clear();
  }

  /// Hands one frame to one connection, registering where that connection's
  /// timeline starts the first time it is given anything.
  void _sendFrame(_Connection connection, Uint8List frame, int frameStartByte) {
    if (connection.firstFrameByte == null) {
      connection.firstFrameByte = frameStartByte;
      _matcher?.openStream(
        connection.streamId,
        startOffset: Duration(
          microseconds: (frameStartByte * 1000000 / _bytesPerSecond).round(),
        ),
      );
    }
    connection.socket.sendAudio(frame);
  }

  void _attachAudio() {
    final pcmStream = _audioSource.start();
    cancelQuietly(_audioSubscription);
    _audioSubscription = pcmStream.listen(
      (data) {
        _lastAudioFrameAt = DateTime.now();

        // A frame is the only proof capture actually works: permission may be
        // granted and the microphone still be taken by another app.
        final confirmation = _captureConfirmed;
        if (confirmation != null && !confirmation.isCompleted) {
          confirmation.complete(true);
        }

        final frameStartByte = _capturedBytes;
        _capturedBytes += data.lengthInBytes;

        if (_awaitingFirstConnect) {
          if (_preConnectFrames.length < _maxPreConnectFrames) {
            _preConnectFrames.add(data);
          }
          return;
        }

        // During a renewal seam both connections get every frame: the incoming
        // one needs real speech before it carries the session alone, and the
        // outgoing one must not go deaf while it still has to.
        final primary = _primary;
        if (primary != null) _sendFrame(primary, data, frameStartByte);
        final pending = _pending;
        if (pending != null) _sendFrame(pending, data, frameStartByte);
      },
      onError: (Object error) {
        final confirmation = _captureConfirmed;
        if (confirmation != null && !confirmation.isCompleted) {
          // Failed before a socket was ever opened, which is the whole point
          // of starting capture first.
          if (error is AudioSourcePermissionDenied) {
            _report('Microphone access is needed for voice counting.');
            _setStatus(EngineStatus.permissionDenied);
          } else {
            _report('Could not start the microphone: $error');
            _setStatus(EngineStatus.error);
          }
          confirmation.complete(false);
          return;
        }

        if (_stopped) return;
        if (error is AudioSourceStalled) {
          // iOS pauses capture on an audio-session interruption and never
          // resumes it, so a restart is the only way back.
          _report('Microphone stopped delivering audio — restarting capture.');
          _scheduleReconnect(restartAudio: true);
        } else {
          _report('Microphone error: $error');
          _scheduleReconnect(restartAudio: true);
        }
      },
    );
  }

  void _startTranscriptionWatchdog() {
    _transcriptionWatchdog?.cancel();
    _transcriptionWatchdog = Timer.periodic(transcriptionWatchdogInterval, (_) {
      if (_stopped || _primary?.socket.currentState != SocketState.connected) {
        return;
      }

      final lastAudio = _lastAudioFrameAt;
      final lastActivity = _lastSocketActivityAt;
      if (lastAudio == null || lastActivity == null) return;

      final now = DateTime.now();
      final audioIsFlowing =
          now.difference(lastAudio) < AudioSource.stallTimeout;
      final serviceIsSilent =
          now.difference(lastActivity) >= transcriptionSilenceTimeout;
      if (!audioIsFlowing || !serviceIsSilent) return;

      _report('Transcription stopped responding. Reconnecting.');
      _stopTranscriptionWatchdog();
      _scheduleReconnect(restartAudio: false);
    });
  }

  void _stopTranscriptionWatchdog() {
    _transcriptionWatchdog?.cancel();
    _transcriptionWatchdog = null;
  }

  /// Schedules a recovery attempt.
  ///
  /// [restartAudio] distinguishes the two failure modes: a dead socket needs
  /// only a new connection, while a stalled microphone needs capture torn down
  /// and rebuilt. Restarting capture unnecessarily costs about a second of
  /// audio and risks re-triggering the iOS interruption path, so we only do it
  /// when the microphone is the thing that failed.
  void _scheduleReconnect({required bool restartAudio}) {
    if (_stopped) return;
    if (_reconnectTimer != null || _reconnectInFlight) return;

    _stopTranscriptionWatchdog();

    _recoveringSince ??= DateTime.now();
    final recoveringFor = DateTime.now().difference(_recoveringSince!);

    // Give up on elapsed time, not attempt count. A fixed handful of attempts
    // covers a few seconds, which is nothing across a 1–2 hour session — a
    // tunnel, a lift, or a Wi-Fi handover routinely exceeds it.
    if (recoveringFor >= reconnectWindow) {
      // Through the same teardown as every other terminal end. Reporting the
      // status alone left the microphone open and the renewal timer armed, so
      // an errored session went on buying blocks it could not use.
      unawaited(
        _endStreaming(
          EngineStatus.error,
          'Could not restore voice counting after '
          '${recoveringFor.inMinutes} min of retrying. Tap the mic to restart.',
        ),
      );
      return;
    }

    _reconnectAttempts++;
    _totalReconnects++;
    _setStatus(EngineStatus.reconnecting);

    _reconnectTimer = Timer(_backoffFor(_reconnectAttempts), () async {
      _reconnectTimer = null;
      if (_stopped) return;

      _reconnectInFlight = true;
      try {
        if (restartAudio) await _abandonCapture();

        final primary = _primary;
        if (primary == null) {
          // Reachable while a session is still starting: a microphone stall
          // during the block round trip schedules a reconnect before any
          // socket exists. Returning here left the engine in `reconnecting`
          // with no timer, no capture and no path to `live` or `error`, so
          // hand the attempt to the retry budget like any other failure.
          throw StateError('there is no voice connection to restore');
        }

        await primary.socket.closeGracefully(drainTimeoutMs: 0);
        await primary.socket.connect(
          apiKeyOrToken: await _reconnectCredential(),
          phrase: _phrase,
        );
        _rebaseAfterReconnect(primary);

        if (restartAudio || _audioSubscription == null) {
          _attachAudio();
        }
      } catch (e) {
        _report('Reconnection failed: $e');
        _reconnectInFlight = false;
        _scheduleReconnect(restartAudio: restartAudio);
        return;
      } finally {
        _reconnectInFlight = false;
      }
    });
  }

  /// The credential a reconnect uses.
  ///
  /// Requirement 5.4 and the design's error table: a reconnect inside the
  /// current block resumes on that block and acquires nothing. Asking again
  /// would not even be refused — the server reads a matching session id as a
  /// renewal — so every dropped socket would buy another block.
  Future<String> _reconnectCredential() async {
    final block = _block;
    if (block != null) return block.deepgramToken;
    final provider = tokenProvider;
    if (provider == null) {
      throw const VoiceUnavailable(
        'Voice counting has no streaming time left to reconnect with.',
      );
    }
    return provider();
  }

  /// A reconnected socket restarts the provider's audio clock at zero, so the
  /// connection becomes a new stream, positioned where the session's audio has
  /// actually reached.
  void _rebaseAfterReconnect(_Connection connection) {
    _matcher?.closeStream(connection.streamId);
    connection.streamId = 'stream-${_streamSeq++}';
    connection.firstFrameByte = null;
  }

  /// Exponential backoff capped at [maxReconnectBackoff], with jitter so a
  /// flapping network does not settle into a lockstep retry rhythm.
  Duration _backoffFor(int attempt) {
    final exponential = Duration(
      milliseconds: 500 * (1 << (attempt - 1).clamp(0, 10)),
    );
    final capped = exponential > maxReconnectBackoff
        ? maxReconnectBackoff
        : exponential;

    final jitter = _random.nextInt(
      (capped.inMilliseconds ~/ 4).clamp(1, 1 << 30),
    );
    return capped + Duration(milliseconds: jitter);
  }

  void _handleDetection(Detection detection) {
    _voiceCount++;
    _seq++;
    _detectionsThisBlock++;

    final event = CountEvent(
      seq: _seq,
      source: CountSource.voice,
      confidence: detection.score,
      audioOffset: detection.audioOffset,
      wallClock: DateTime.now(),
    );

    if (!_countsController.isClosed) {
      _countsController.add(event);
    }
  }

  /// Increment manual count during active voice session.
  @override
  void incrementManual() {
    _manualCount++;
    _seq++;

    final event = CountEvent(
      seq: _seq,
      source: CountSource.manual,
      confidence: 1.0,
      audioOffset: Duration.zero,
      wallClock: DateTime.now(),
    );

    if (!_countsController.isClosed) {
      _countsController.add(event);
    }
  }

  /// Removes the most recent manual count, flooring at zero.
  @override
  void decrementManual() {
    if (_manualCount == 0) return;
    _manualCount--;
  }

  @override
  Future<SessionSummary> stop() async {
    // Set before any await: teardown makes the socket emit `disconnected`, and
    // without this flag that callback would schedule a reconnect for the very
    // session we are ending.
    _stopped = true;
    _cancelTimers();
    _preConnectFrames.clear();

    // A stop during startup — before capture has delivered its first frame —
    // cancels the very subscription that would confirm or refuse it. Without
    // this the pending `start()` waits on a completer nothing can ever finish.
    final pendingConfirmation = _captureConfirmed;
    if (pendingConfirmation != null && !pendingConfirmation.isCompleted) {
      pendingConfirmation.complete(false);
    }

    try {
      await _abandonCapture();
      await _closeConnections();
    } catch (e) {
      // Teardown is best-effort. Whatever fails, the session is over and the
      // UI must be told so — otherwise the stop button appears not to work.
      _report('Voice session did not shut down cleanly: $e');
    }

    _setStatus(EngineStatus.idle);

    // 3.5: the block is reported on after streaming has actually stopped, so
    // the streamed seconds and detection count are final.
    await _releaseBlock();

    final now = DateTime.now();
    final duration = _startTime != null
        ? now.difference(_startTime!)
        : Duration.zero;

    return SessionSummary(
      voiceCount: _voiceCount,
      manualCount: _manualCount,
      totalCount: totalCount,
      duration: duration,
    );
  }

  @override
  Future<void> dispose() async {
    await stop();
    for (final socket in _ownedSockets.toList()) {
      await socket.dispose();
    }
    _ownedSockets.clear();
    await _audioSource.dispose();
    await _countsController.close();
    await _statusController.close();
    await _diagnosticsController.close();
  }
}
