import 'dart:async';
import 'dart:typed_data';

import 'counting_engine.dart';
import 'transcript_segment.dart';

/// Connection state of a streaming speech recognition socket.
enum SocketState { disconnected, connecting, connected, closing, error }

/// What a socket authenticates with, and so how it has to be presented.
///
/// The two kinds are not interchangeable, and a provider rejects one sent as
/// the other. This used to be a bare string named `apiKeyOrToken`, which told
/// the socket nothing: it presented everything as an API key, so every
/// session that paid for a temporary token was refused at the handshake while
/// dev builds, which do hold an API key, worked. Making the kind part of the
/// value means a caller cannot hand over a credential without saying what it
/// is.
class SpeechCredential {
  /// A long-lived key. Only ever held by a dev build.
  const SpeechCredential.apiKey(this.value) : isTemporary = false;

  /// A short-lived token minted by the voice service for one block.
  const SpeechCredential.temporaryToken(this.value) : isTemporary = true;

  final String value;
  final bool isTemporary;

  /// Never the value: this ends up in logs and test failure output.
  @override
  String toString() =>
      'SpeechCredential(${isTemporary ? 'temporaryToken' : 'apiKey'})';
}

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

  /// Connect to the provider's streaming endpoint.
  Future<void> connect({
    required SpeechCredential credential,
    PhraseSet? phrases,
  });

  /// Stream binary PCM16 audio frames to the socket.
  void sendAudio(Uint8List pcmFrames);

  /// Gracefully close the connection after draining trailing transcript results.
  ///
  /// Must return in bounded time whatever state the connection is in,
  /// including one that never opened. The engine awaits this while tearing a
  /// session down, so an implementation that can wait for ever turns a failed
  /// connection into a frozen app. The same holds for [dispose].
  Future<void> closeGracefully({int drainTimeoutMs = 2000});

  /// Dispose all stream controllers and socket resources.
  Future<void> dispose();
}
