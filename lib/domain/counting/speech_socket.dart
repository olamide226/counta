import 'dart:async';
import 'dart:typed_data';

import 'counting_engine.dart';
import 'transcript_segment.dart';

/// Connection state of a streaming speech recognition socket.
enum SocketState { disconnected, connecting, connected, closing, error }

/// Abstract contract for streaming speech-to-text WebSocket clients.
///
/// Any provider (Deepgram, AssemblyAI, Whisper, etc.) implements this contract,
/// keeping phrase matching, session tracking, and UI decoupled from vendor APIs.
abstract class SpeechSocket {
  /// Stream of finalized and interim transcript segments.
  Stream<TranscriptSegment> get segments;

  /// Stream of socket connection state changes.
  Stream<SocketState> get state;

  /// Emits whenever the transcription service sends any message, including an
  /// empty result. Used to detect a connection that looks open but has stopped
  /// responding.
  Stream<void> get activity;

  /// Current connection state.
  SocketState get currentState;

  /// Why the connection last closed, when the provider told us.
  ///
  /// Null before the first close, or when the socket dropped without a reason.
  /// Surfaced to the user so an interrupted session explains itself instead of
  /// silently ending.
  String? get closeDescription;

  /// Connect to the provider's streaming endpoint with an API key/token and target phrase parameters.
  Future<void> connect({required String apiKeyOrToken, PhraseSpec? phrase});

  /// Stream binary PCM16 audio frames to the socket.
  void sendAudio(Uint8List pcmFrames);

  /// Gracefully close the connection after draining trailing transcript results.
  Future<void> closeGracefully({int drainTimeoutMs = 2000});

  /// Dispose all stream controllers and socket resources.
  Future<void> dispose();
}
