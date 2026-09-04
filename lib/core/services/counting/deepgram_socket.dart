import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../domain/counting/counting_engine.dart';
import '../../../domain/counting/speech_socket.dart';
import '../../../domain/counting/transcript_segment.dart';

class DeepgramSocket implements SpeechSocket {
  WebSocketChannel? _channel;
  StreamSubscription? _socketSubscription;
  Timer? _keepAliveTimer;

  final StreamController<TranscriptSegment> _segmentController =
      StreamController<TranscriptSegment>.broadcast();
  final StreamController<SocketState> _stateController =
      StreamController<SocketState>.broadcast();
  final StreamController<void> _activityController =
      StreamController<void>.broadcast();

  SocketState _state = SocketState.disconnected;
  DateTime _lastAudioSentAt = DateTime.now();
  String? _closeDescription;

  /// Wall-clock moment the first audio frame went out. Anchors Deepgram's
  /// audio-timeline offsets to real time so we can measure end-to-end lag.
  DateTime? _audioStartedAt;

  @override
  Stream<TranscriptSegment> get segments => _segmentController.stream;
  @override
  Stream<SocketState> get state => _stateController.stream;
  @override
  Stream<void> get activity => _activityController.stream;
  @override
  SocketState get currentState => _state;
  @override
  String? get closeDescription => _closeDescription;

  void _setState(SocketState newState) {
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(_state);
    }
  }

  /// Construct the WebSocket URI for Deepgram Nova-3 listen endpoint cleanly via Uri.parse.
  static Uri buildUri({required PhraseSpec? phrase}) {
    final queryComponents = <String>[
      'model=nova-3',
      'language=${Uri.encodeComponent(phrase?.languageCode ?? 'en')}',
      'encoding=linear16',
      'sample_rate=16000',
      'channels=1',
      'interim_results=true',
      'endpointing=300',
      'utterance_end_ms=1000',
      'no_delay=true',
      'smart_format=false',
      'punctuate=false',
      'numerals=false',
      'mip_opt_out=true',
    ];

    if (phrase != null && phrase.keyterms.isNotEmpty) {
      final cleanKeyterm = phrase.keyterms.first
          .replaceAll(RegExp(r'[^\w\s]'), '')
          .trim();
      if (cleanKeyterm.isNotEmpty) {
        queryComponents.add('keyterm=${Uri.encodeComponent(cleanKeyterm)}');
      }
    }

    final fullUrl =
        'wss://api.deepgram.com:443/v1/listen?${queryComponents.join('&')}';
    return Uri.parse(fullUrl);
  }

  /// Connect to Deepgram WebSocket.
  @override
  Future<void> connect({
    required String apiKeyOrToken,
    PhraseSpec? phrase,
    WebSocketChannel Function(Uri uri, Map<String, dynamic> headers)?
    channelFactory,
  }) async {
    if (_state == SocketState.connected || _state == SocketState.connecting) {
      return;
    }

    _closeDescription = null;
    _audioStartedAt = null;
    _setState(SocketState.connecting);
    final uri = buildUri(phrase: phrase);
    final headers = {'Authorization': 'Token $apiKeyOrToken'};

    try {
      if (channelFactory != null) {
        _channel = channelFactory(uri, headers);
      } else {
        if (kIsWeb) {
          _channel = WebSocketChannel.connect(uri);
        } else {
          _channel = IOWebSocketChannel.connect(uri, headers: headers);
        }
      }

      await _channel!.ready;
      _setState(SocketState.connected);
      _startKeepAliveTimer();

      _socketSubscription = _channel!.stream.listen(
        _handleMessage,
        onError: (error) {
          _closeDescription = 'Connection error: $error';
          _setState(SocketState.error);
        },
        onDone: () {
          // Deepgram signals *why* it hung up via the WebSocket close frame —
          // e.g. 1011/NET-0001 for an audio timeout, 4001 for a bad API key.
          // Without capturing it here the reason is lost and a dropped session
          // looks identical to a clean one.
          _closeDescription = _describeClose(
            _channel?.closeCode,
            _channel?.closeReason,
          );
          if (_state != SocketState.closing) {
            _setState(SocketState.disconnected);
          }
        },
      );
    } catch (e) {
      _closeDescription = 'Could not connect: $e';
      _setState(SocketState.error);
      rethrow;
    }
  }

  /// Turn a WebSocket close frame into something worth showing a user.
  static String? _describeClose(int? code, String? reason) {
    final detail = (reason != null && reason.isNotEmpty) ? reason : null;

    return switch (code) {
      null => detail,
      1000 => null, // Normal closure — nothing to explain.
      1011 =>
        'Transcription timed out'
            '${detail != null ? ' ($detail)' : ' — no audio was reaching the server'}.',
      4001 || 4008 || 4009 =>
        'Transcription rejected the API key${detail != null ? ' ($detail)' : ''}.',
      _ =>
        'Transcription closed (code $code)'
            '${detail != null ? ': $detail' : '.'}',
    };
  }

  void _handleMessage(dynamic message) {
    if (!_activityController.isClosed) {
      _activityController.add(null);
    }
    if (message is! String) return;

    try {
      final jsonMap = jsonDecode(message) as Map<String, dynamic>;
      final type = jsonMap['type'] as String?;

      if (type == 'Results') {
        final segment = TranscriptSegment.fromDeepgramJson(jsonMap);
        if (segment.text.isNotEmpty && !_segmentController.isClosed) {
          _segmentController.add(segment.copyWith(lag: _lagFor(segment)));
        }
      }
    } catch (_) {}
  }

  /// How far behind live this result arrived.
  ///
  /// Deepgram timestamps results against the audio stream, so anchoring that
  /// timeline to when we started sending gives the true round trip rather than
  /// just the network hop.
  Duration? _lagFor(TranscriptSegment segment) {
    final startedAt = _audioStartedAt;
    if (startedAt == null) return null;

    final elapsed = DateTime.now().difference(startedAt);
    final audioPosition = Duration(
      microseconds: (segment.endOffset * Duration.microsecondsPerSecond)
          .round(),
    );

    final lag = elapsed - audioPosition;
    return lag.isNegative ? Duration.zero : lag;
  }

  /// Send binary PCM audio frames over WebSocket safely.
  @override
  void sendAudio(Uint8List pcmFrames) {
    if (_state != SocketState.connected || _channel == null) return;
    try {
      _channel!.sink.add(pcmFrames);
      _audioStartedAt ??= DateTime.now();
      _lastAudioSentAt = DateTime.now();
    } catch (_) {
      _setState(SocketState.error);
    }
  }

  /// Send explicit KeepAlive ping message every 5s of silent audio transmission.
  void _startKeepAliveTimer() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_state == SocketState.connected && _channel != null) {
        final quietDuration = DateTime.now().difference(_lastAudioSentAt);
        if (quietDuration.inSeconds >= 5) {
          try {
            _channel!.sink.add(jsonEncode({'type': 'KeepAlive'}));
          } catch (_) {}
        }
      }
    });
  }

  /// Graceful shutdown: send CloseStream, wait up to 1000 ms for trailing final results, then close safely.
  @override
  Future<void> closeGracefully({int drainTimeoutMs = 1000}) async {
    _keepAliveTimer?.cancel();

    if (_state == SocketState.connected && _channel != null) {
      _setState(SocketState.closing);
      try {
        _channel!.sink.add(jsonEncode({'type': 'CloseStream'}));
        await Future.delayed(Duration(milliseconds: drainTimeoutMs));
      } catch (_) {}
    }

    await _socketSubscription?.cancel();
    _socketSubscription = null;

    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;

    _setState(SocketState.disconnected);
  }

  /// Immediately close and clean up resources safely.
  @override
  Future<void> dispose() async {
    _keepAliveTimer?.cancel();
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;

    if (!_segmentController.isClosed) await _segmentController.close();
    if (!_stateController.isClosed) await _stateController.close();
    if (!_activityController.isClosed) await _activityController.close();
  }
}
