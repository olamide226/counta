import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_source.dart';
import 'deepgram_socket.dart';
import '../../../domain/counting/counting_engine.dart';
import '../../../domain/counting/phrase_matcher.dart';
import '../../../domain/counting/speech_socket.dart';
import '../../../domain/counting/transcript_segment.dart';

/// Concrete implementation of [CountingEngine] using cloud streaming STT (Deepgram/SpeechSocket),
/// [AudioSource] PCM capture, and local [PhraseMatcher].
class CloudCountingEngine implements CountingEngine {
  final AudioSource _audioSource;
  final SpeechSocket _speechSocket;
  final MatcherConfig matcherConfig;
  final String apiKeyOrToken;

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
  StreamSubscription<TranscriptSegment>? _segmentSubscription;
  StreamSubscription<SocketState>? _socketStateSubscription;
  StreamSubscription<void>? _socketActivitySubscription;

  PhraseMatcher? _matcher;
  PhraseSpec? _phrase;
  EngineStatus _status = EngineStatus.idle;
  int _seq = 0;
  int _voiceCount = 0;
  int _manualCount = 0;
  DateTime? _startTime;

  /// True once [stop] has been called, so late socket/audio callbacks from the
  /// teardown do not schedule a reconnect for a session the user ended.
  bool _stopped = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  Timer? _transcriptionWatchdog;
  DateTime? _lastSocketActivityAt;
  DateTime? _lastAudioFrameAt;

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

  CloudCountingEngine({
    AudioSource? audioSource,
    SpeechSocket? speechSocket,
    this.matcherConfig = const MatcherConfig(),
    this.reconnectWindow = const Duration(minutes: 5),
    this.maxReconnectBackoff = const Duration(seconds: 15),
    this.transcriptionSilenceTimeout = const Duration(seconds: 20),
    this.transcriptionWatchdogInterval = const Duration(seconds: 5),
    String? apiKeyOrToken,
  }) : _audioSource = audioSource ?? AudioSource(),
       _speechSocket = speechSocket ?? DeepgramSocket(),
       apiKeyOrToken =
           apiKeyOrToken ?? const String.fromEnvironment('DEEPGRAM_API_KEY');

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
    _startTime = DateTime.now();
    _phrase = targetPhrase;
    _matcher = PhraseMatcher(target: targetPhrase, config: matcherConfig);

    // Ask for the microphone before anything else. Opening the socket first
    // would spend streaming time (and, once credits exist, money) on a session
    // that can never deliver audio.
    if (!await _audioSource.hasPermission()) {
      _report('Microphone access is needed for voice counting.');
      _setStatus(EngineStatus.permissionDenied);
      return;
    }
    if (_stopped) return;

    _setStatus(EngineStatus.connecting);

    // Attach socket state listener
    _socketStateSubscription?.cancel();
    _socketStateSubscription = _speechSocket.state.listen((sState) {
      switch (sState) {
        case SocketState.connecting:
          _setStatus(EngineStatus.connecting);
          break;
        case SocketState.connected:
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
              _speechSocket.closeDescription ??
                  'Transcription connection closed unexpectedly.',
            );
            _scheduleReconnect(restartAudio: false);
          }
          break;
        case SocketState.error:
          _stopTranscriptionWatchdog();
          if (!_stopped) {
            _report(
              _speechSocket.closeDescription ??
                  'Transcription connection errored.',
            );
            _scheduleReconnect(restartAudio: false);
          }
          break;
      }
    });

    _socketActivitySubscription?.cancel();
    _socketActivitySubscription = _speechSocket.activity.listen((_) {
      _lastSocketActivityAt = DateTime.now();
    });

    // Attach segment listener -> PhraseMatcher
    _segmentSubscription?.cancel();
    _segmentSubscription = _speechSocket.segments.listen((segment) {
      if (_matcher == null) return;
      final detections = _matcher!.ingest(segment);
      for (final detection in detections) {
        _handleDetection(detection);
      }
    });

    try {
      await _speechSocket.connect(
        apiKeyOrToken: apiKeyOrToken,
        phrase: targetPhrase,
      );
      _attachAudio();
    } catch (e) {
      _report('Could not start voice session: $e');
      _setStatus(EngineStatus.error);
      rethrow;
    }
  }

  void _attachAudio() {
    final pcmStream = _audioSource.start();
    _audioSubscription?.cancel();
    _audioSubscription = pcmStream.listen(
      (data) {
        _lastAudioFrameAt = DateTime.now();
        _speechSocket.sendAudio(data);
      },
      onError: (Object error) {
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
      if (_stopped || _speechSocket.currentState != SocketState.connected) {
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
      _report(
        'Could not restore voice counting after '
        '${recoveringFor.inMinutes} min of retrying. Tap the mic to restart.',
      );
      _setStatus(EngineStatus.error);
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
        if (restartAudio) {
          await _audioSubscription?.cancel();
          _audioSubscription = null;
          await _audioSource.stop();
        }

        await _speechSocket.closeGracefully(drainTimeoutMs: 0);
        await _speechSocket.connect(
          apiKeyOrToken: apiKeyOrToken,
          phrase: _phrase,
        );

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
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopTranscriptionWatchdog();

    try {
      await _audioSubscription?.cancel();
      _audioSubscription = null;
      await _audioSource.stop();

      await _speechSocket.closeGracefully();
      await _segmentSubscription?.cancel();
      _segmentSubscription = null;
      await _socketStateSubscription?.cancel();
      _socketStateSubscription = null;
      await _socketActivitySubscription?.cancel();
      _socketActivitySubscription = null;
    } catch (e) {
      // Teardown is best-effort. Whatever fails, the session is over and the UI
      // must be told so — otherwise the stop button appears not to work.
      _report('Voice session did not shut down cleanly: $e');
    } finally {
      _setStatus(EngineStatus.idle);
    }

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
    await _speechSocket.dispose();
    await _audioSource.dispose();
    await _countsController.close();
    await _statusController.close();
    await _diagnosticsController.close();
  }
}
