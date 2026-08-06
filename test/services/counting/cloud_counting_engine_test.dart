import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

import 'package:counta/core/services/counting/cloud_counting_engine.dart';
import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/domain/counting/speech_socket.dart';
import 'package:counta/domain/counting/transcript_segment.dart';
import 'package:counta/core/services/counting/audio_source.dart';

class FakeSpeechSocket implements SpeechSocket {
  final _segmentsController = StreamController<TranscriptSegment>.broadcast();
  final _stateController = StreamController<SocketState>.broadcast();
  SocketState _currentState = SocketState.disconnected;

  @override
  Stream<TranscriptSegment> get segments => _segmentsController.stream;

  @override
  Stream<SocketState> get state => _stateController.stream;

  @override
  SocketState get currentState => _currentState;

  @override
  String? closeDescription;

  @override
  Future<void> connect({required String apiKeyOrToken, PhraseSpec? phrase}) async {
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
    _segmentsController.add(segment);
  }

  @override
  void sendAudio(Uint8List pcmFrames) {}

  @override
  Future<void> closeGracefully({int drainTimeoutMs = 2000}) async {
    _currentState = SocketState.disconnected;
    _stateController.add(_currentState);
  }

  @override
  Future<void> dispose() async {
    await _segmentsController.close();
    await _stateController.close();
  }
}

class FakeAudioSource implements AudioSource {
  StreamController<Uint8List>? _controller;
  int startCount = 0;
  int stopCount = 0;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Stream<Uint8List> start({int sampleRate = 16000}) {
    startCount++;
    // A fresh controller per start, so the engine can restart capture after a
    // stall the same way the real source does.
    _controller = StreamController<Uint8List>.broadcast();
    return _controller!.stream;
  }

  /// Simulates iOS pausing capture without closing the stream.
  void emitStall() {
    _controller?.addError(const AudioSourceStalled(Duration(seconds: 3)));
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

void main() {
  group('CloudCountingEngine', () {
    late FakeSpeechSocket fakeSocket;
    late FakeAudioSource fakeAudio;
    late CloudCountingEngine engine;

    setUp(() {
      fakeSocket = FakeSpeechSocket();
      fakeAudio = FakeAudioSource();
      engine = CloudCountingEngine(
        speechSocket: fakeSocket,
        audioSource: fakeAudio,
      );
    });

    tearDown(() async {
      await engine.dispose();
    });

    test('start transitions status to connecting then live', () async {
      await engine.start(const PhraseSpec(
        raw: "I'm rich in wisdom",
        normalisedTokens: ['i', 'am', 'rich', 'in', 'wisdom'],
      ));

      expect(engine.currentStatus, EngineStatus.live);
    });

    test('emits CountEvent on phrase detection from transcript stream', () async {
      final events = <CountEvent>[];
      final sub = engine.counts.listen(events.add);

      await engine.start(const PhraseSpec(
        raw: "I'm rich in wisdom",
        normalisedTokens: ['i', 'am', 'rich', 'in', 'wisdom'],
      ));

      // Emit matching segment
      fakeSocket.emitSegment(TranscriptSegment(
        text: "I'm rich in wisdom",
        start: 1.0,
        duration: 2.0,
        isFinal: true,
        confidence: 0.99,
      ));

      await pumpEventQueue();

      expect(events.length, 1);
      expect(events.first.source, CountSource.voice);
      expect(engine.voiceCount, 1);
      expect(engine.totalCount, 1);

      await sub.cancel();
    });

    test('incrementManual increments manual count and emits CountSource.manual event', () async {
      final events = <CountEvent>[];
      final sub = engine.counts.listen(events.add);

      await engine.start();
      engine.incrementManual();

      await pumpEventQueue();

      expect(events.length, 1);
      expect(events.first.source, CountSource.manual);
      expect(engine.manualCount, 1);
      expect(engine.totalCount, 1);

      await sub.cancel();
    });

    test('stop always lands on idle, even if teardown throws', () async {
      final throwingSocket = _ThrowingCloseSocket();
      final localEngine = CloudCountingEngine(
        speechSocket: throwingSocket,
        audioSource: FakeAudioSource(),
      );

      await localEngine.start();
      final summary = await localEngine.stop();

      // Regression: teardown used to run without a guard, so a throwing close
      // skipped the status update and the UI stayed stuck showing an active
      // voice session with a stop button that appeared dead.
      expect(localEngine.currentStatus, EngineStatus.idle);
      expect(summary.totalCount, 0);
    });

    test('an unrequested drop reports why, instead of going quietly idle',
        () async {
      final reasons = <String>[];
      final statuses = <EngineStatus>[];
      final diagSub = engine.diagnostics.listen(reasons.add);
      final statusSub = engine.status.listen(statuses.add);

      await engine.start();
      fakeSocket.emitDrop(reason: 'Transcription timed out.');
      await pumpEventQueue();

      expect(reasons, contains('Transcription timed out.'));
      expect(engine.currentStatus, EngineStatus.reconnecting);
      expect(statuses, isNot(contains(EngineStatus.idle)));

      await diagSub.cancel();
      await statusSub.cancel();
    });

    test('a microphone stall triggers a reconnect rather than silent death',
        () async {
      final reasons = <String>[];
      final sub = engine.diagnostics.listen(reasons.add);

      await engine.start();
      fakeAudio.emitStall();
      await pumpEventQueue();

      expect(reasons.single, contains('Microphone stopped delivering audio'));
      expect(engine.currentStatus, EngineStatus.reconnecting);

      await sub.cancel();
    });

    test('keeps retrying well past a handful of attempts', () async {
      // The point of the retry budget being time-based: a 30-second outage in
      // the middle of a 90-minute session must not end the session.
      final failing = _FailingReconnectSocket();
      final localEngine = CloudCountingEngine(
        speechSocket: failing,
        audioSource: FakeAudioSource(),
        reconnectWindow: const Duration(minutes: 5),
        maxReconnectBackoff: const Duration(milliseconds: 20),
      );

      await localEngine.start();
      failing.failConnects = true;
      failing.emitDrop(reason: 'dropped');

      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(
        failing.connectAttempts,
        greaterThan(4),
        reason: 'a fixed 3-attempt budget would have given up by now',
      );
      expect(localEngine.currentStatus, EngineStatus.reconnecting);

      await localEngine.stop();
    });

    test('gives up only after the reconnect window elapses', () async {
      final failing = _FailingReconnectSocket();
      final localEngine = CloudCountingEngine(
        speechSocket: failing,
        audioSource: FakeAudioSource(),
        reconnectWindow: const Duration(milliseconds: 120),
        maxReconnectBackoff: const Duration(milliseconds: 10),
      );

      await localEngine.start();
      failing.failConnects = true;
      failing.emitDrop(reason: 'dropped');

      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(localEngine.currentStatus, EngineStatus.error);
      await localEngine.stop();
    });

    test('a socket drop does not tear down a healthy microphone', () async {
      await engine.start();
      final startsBefore = fakeAudio.startCount;

      fakeSocket.emitDrop(reason: 'server hung up');
      await Future<void>.delayed(const Duration(milliseconds: 900));

      // Capture is fine; only the connection failed. Restarting the mic would
      // cost about a second of audio and risk the iOS interruption path.
      expect(fakeAudio.stopCount, 0);
      expect(fakeAudio.startCount, startsBefore);
    });

    test('a recovered drop banks downtime and resets the retry budget',
        () async {
      await engine.start();

      fakeSocket.emitDrop(reason: 'blip');
      await Future<void>.delayed(const Duration(milliseconds: 900));

      expect(engine.currentStatus, EngineStatus.live);
      expect(engine.totalReconnects, 1);
      expect(engine.downtime, greaterThan(Duration.zero));
    });

    test('stopping during a pending reconnect does not resurrect the session',
        () async {
      await engine.start();
      fakeAudio.emitStall();
      await pumpEventQueue();
      expect(engine.currentStatus, EngineStatus.reconnecting);

      await engine.stop();
      final startsAtStop = fakeAudio.startCount;

      // Let the backoff timer's deadline pass.
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(engine.currentStatus, EngineStatus.idle);
      expect(fakeAudio.startCount, startsAtStop);
    });
  });
}

/// A socket that can be told to refuse reconnections, standing in for a
/// network outage that lasts longer than a couple of seconds.
class _FailingReconnectSocket extends FakeSpeechSocket {
  bool failConnects = false;
  int connectAttempts = 0;

  @override
  Future<void> connect({
    required String apiKeyOrToken,
    PhraseSpec? phrase,
  }) async {
    connectAttempts++;
    if (failConnects) {
      throw const SocketException('network unreachable');
    }
    return super.connect(apiKeyOrToken: apiKeyOrToken, phrase: phrase);
  }

  @override
  Future<void> closeGracefully({int drainTimeoutMs = 2000}) async {}
}

/// A socket whose graceful close fails, standing in for a platform channel that
/// throws while the user is trying to end a session.
class _ThrowingCloseSocket extends FakeSpeechSocket {
  @override
  Future<void> closeGracefully({int drainTimeoutMs = 2000}) async {
    throw StateError('channel already torn down');
  }
}
