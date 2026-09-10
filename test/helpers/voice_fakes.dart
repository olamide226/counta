import 'dart:async';
import 'dart:typed_data';

import 'package:counta/core/services/counting/audio_source.dart';
import 'package:counta/domain/counting/block_service.dart';
import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/domain/counting/speech_socket.dart';
import 'package:counta/domain/counting/transcript_segment.dart';

const testToken = 'test-deepgram-token';

class FakeSpeechSocket implements SpeechSocket {
  FakeSpeechSocket([this.name = 'socket']);

  /// Distinguishes the two connections at a renewal seam in a failure message.
  final String name;

  /// Every credential the engine handed to [connect], in order.
  final List<String> tokensSeen = [];
  final _segmentsController = StreamController<TranscriptSegment>.broadcast();
  final _stateController = StreamController<SocketState>.broadcast();
  final _activityController = StreamController<void>.broadcast();
  SocketState _currentState = SocketState.disconnected;

  @override
  Stream<TranscriptSegment> get segments => _segmentsController.stream;

  @override
  Stream<SocketState> get state => _stateController.stream;

  @override
  Stream<void> get activity => _activityController.stream;

  @override
  SocketState get currentState => _currentState;

  @override
  String? closeDescription;

  int connectCount = 0;
  int closeCount = 0;
  bool disposed = false;

  @override
  Future<void> connect({
    required String apiKeyOrToken,
    PhraseSpec? phrase,
  }) async {
    connectCount++;
    tokensSeen.add(apiKeyOrToken);
    _currentState = SocketState.connected;
    _stateController.add(_currentState);
  }

  /// Simulates the server hanging up mid-session, without the engine asking.
  void emitDrop({String? reason}) {
    closeDescription = reason;
    _currentState = SocketState.disconnected;
    _stateController.add(_currentState);
  }

  void emitSegment(TranscriptSegment segment) {
    _activityController.add(null);
    _segmentsController.add(segment);
  }

  void emitActivity() => _activityController.add(null);

  final List<Uint8List> sentFrames = [];

  @override
  void sendAudio(Uint8List pcmFrames) => sentFrames.add(pcmFrames);

  @override
  Future<void> closeGracefully({int drainTimeoutMs = 2000}) async {
    closeCount++;
    _currentState = SocketState.disconnected;
    _stateController.add(_currentState);
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await _segmentsController.close();
    await _stateController.close();
    await _activityController.close();
  }
}

class FakeAudioSource implements AudioSource {
  StreamController<Uint8List>? _controller;
  int startCount = 0;
  int stopCount = 0;

  /// What the OS answers when capture asks for the microphone.
  bool permissionGranted = true;

  /// Holds the stream silent: no first frame, no error. Models a microphone
  /// that has been granted but never delivers, so a stop can race startup.
  bool silent = false;

  @override
  Future<bool> hasPermission() async => permissionGranted;

  @override
  Stream<Uint8List> start({int sampleRate = 16000}) {
    startCount++;
    // A fresh controller per start, so the engine can restart capture after a
    // stall the same way the real source does.
    _controller = StreamController<Uint8List>.broadcast();

    // The real source answers on the stream, asynchronously: a refusal as a
    // typed error, and a working microphone as its first frame.
    scheduleMicrotask(() {
      if (silent) {
        return;
      }
      if (!permissionGranted) {
        _controller?.addError(const AudioSourcePermissionDenied());
      } else {
        _controller?.add(Uint8List(320));
      }
    });
    return _controller!.stream;
  }

  /// Simulates iOS pausing capture without closing the stream.
  void emitStall() {
    _controller?.addError(const AudioSourceStalled(Duration(seconds: 3)));
  }

  void emitFrame([int bytes = 320]) {
    _controller?.add(Uint8List(bytes));
  }

  @override
  Future<void> stop() async {
    stopCount++;
    final controller = _controller;
    _controller = null;
    await controller?.close();
  }

  @override
  Future<void> dispose() async {
    await stop();
  }
}

/// A block service that grants from a script, so a test can say exactly what
/// the Edge Function answers on the first call and on each renewal.
class FakeBlockService implements BlockService {
  FakeBlockService({
    this.blockSeconds = 300,
    this.balance = 100,
    this.failures = const [],
    this.refreshFailures = const [],
  });

  final int blockSeconds;
  int balance;

  /// Answers by acquire attempt: index 0 is the session's first block. A null
  /// entry (or running off the end) means an ordinary grant.
  final List<BlockFailure?> failures;

  /// Answers by token-refresh attempt, the same way [failures] answers
  /// acquires.
  final List<BlockFailure?> refreshFailures;

  /// Every block a reconnect asked for a fresh credential on, in order.
  final List<String> refreshedBlockIds = [];

  final List<String> acquiredSessionIds = [];
  final List<ReleaseCall> releases = [];
  final _balance = StreamController<int>.broadcast();

  int _granted = 0;
  bool disposed = false;

  /// Every block this service has handed out, in order.
  final List<VoiceBlock> granted = [];

  @override
  Stream<int> get balanceUpdates => _balance.stream;

  @override
  Future<VoiceBlock> acquire(String sessionId) async {
    final attempt = acquiredSessionIds.length;
    acquiredSessionIds.add(sessionId);

    final failure = attempt < failures.length ? failures[attempt] : null;
    if (failure != null) throw failure;

    _granted++;
    final block = VoiceBlock(
      id: 'block-$_granted',
      deepgramToken: 'token-$_granted',
      blockSeconds: blockSeconds,
      expiresAt: DateTime.now().add(Duration(seconds: blockSeconds)),
      balanceAfter: balance -= 5,
    );
    granted.add(block);
    if (!_balance.isClosed) _balance.add(block.balanceAfter);
    return block;
  }

  @override
  Future<String> refreshToken(String blockId) async {
    final attempt = refreshedBlockIds.length;
    refreshedBlockIds.add(blockId);

    final failure = attempt < refreshFailures.length
        ? refreshFailures[attempt]
        : null;
    if (failure != null) throw failure;

    // Deliberately unlike the grant tokens: replaying the block's own token
    // is the bug the refresh endpoint exists to fix, so a test can see the
    // difference.
    return 'refresh-${refreshedBlockIds.length}';
  }

  @override
  Future<BlockRelease> release(
    String blockId, {
    required int streamedSecs,
    required int detections,
    required bool eligibleForRefund,
  }) async {
    releases.add(
      ReleaseCall(
        blockId: blockId,
        streamedSecs: streamedSecs,
        detections: detections,
        eligibleForRefund: eligibleForRefund,
      ),
    );
    return const BlockRelease(refunded: false);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _balance.close();
  }
}

class ReleaseCall {
  const ReleaseCall({
    required this.blockId,
    required this.streamedSecs,
    required this.detections,
    required this.eligibleForRefund,
  });

  final String blockId;
  final int streamedSecs;
  final int detections;
  final bool eligibleForRefund;

  @override
  String toString() =>
      'ReleaseCall($blockId, streamed: $streamedSecs, detections: $detections, '
      'eligible: $eligibleForRefund)';
}

/// A finalised transcript segment on a connection's own audio timeline.
TranscriptSegment finalSegment(
  String text, {
  double start = 1.0,
  double duration = 2.0,
}) => TranscriptSegment(
  text: text,
  start: start,
  duration: duration,
  isFinal: true,
  confidence: 0.98,
);

const testPhrase = PhraseSpec(
  raw: "I'm rich in wisdom",
  normalisedTokens: ['i', 'am', 'rich', 'in', 'wisdom'],
);
