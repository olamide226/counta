import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:counta/core/services/counting/deepgram_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/domain/counting/speech_socket.dart';

void main() {
  group('DeepgramSocket', () {
    test('conforms to SpeechSocket interface', () {
      final socket = DeepgramSocket();
      expect(socket, isA<SpeechSocket>());
      expect(socket.currentState, SocketState.disconnected);
    });

    test('buildUri constructs correct connection parameters', () {
      const phrase = PhraseSpec(
        raw: "I'm rich in wisdom",
        normalisedTokens: ['i', 'am', 'rich', 'in', 'wisdom'],
        keyterms: ['rich in wisdom'],
      );

      final uri = DeepgramSocket.buildUri(phrases: PhraseSet.single(phrase));

      expect(uri.scheme, 'wss');
      expect(uri.host, 'api.deepgram.com');
      expect(uri.path, '/v1/listen');
      expect(uri.queryParameters['model'], 'nova-3');
      expect(uri.queryParameters['encoding'], 'linear16');
      expect(uri.queryParameters['sample_rate'], '16000');
      expect(uri.queryParameters['channels'], '1');
      expect(uri.queryParameters['interim_results'], 'true');
      expect(uri.queryParameters['endpointing'], '300');
      expect(uri.queryParameters['utterance_end_ms'], '1000');
      expect(uri.queryParameters['no_delay'], 'true');
      expect(uri.queryParameters['smart_format'], 'false');
      expect(uri.queryParameters['punctuate'], 'false');
      expect(uri.queryParameters['numerals'], 'false');
      expect(uri.queryParameters['mip_opt_out'], 'true');
      expect(uri.queryParameters['keyterm'], 'rich in wisdom');
    });

    test('every phrase gets its own keyterm parameter', () {
      // Nova-3 boosts several terms by repeating the parameter. Joining them
      // with a comma would ask it to recognise one absurd term instead of
      // three, so `queryParametersAll` is what has to hold them.
      final uri = DeepgramSocket.buildUri(
        phrases: PhraseSet([
          const PhraseSpec(
            raw: "I'm rich in wisdom",
            normalisedTokens: ['i', 'am', 'rich', 'in', 'wisdom'],
            keyterms: ["I'm rich in wisdom"],
          ),
          const PhraseSpec(
            raw: 'I walk in favour',
            normalisedTokens: ['i', 'walk', 'in', 'favour'],
            keyterms: ['I walk in favour'],
          ),
        ]),
      );

      expect(uri.queryParametersAll['keyterm'], [
        // Punctuation stripped, spaces kept: a multi-word term stays one term.
        'Im rich in wisdom',
        'I walk in favour',
      ]);
    });

    test('a keyterm repeated across phrases is only sent once', () {
      final uri = DeepgramSocket.buildUri(
        phrases: PhraseSet([
          const PhraseSpec(
            raw: 'I walk in favour',
            normalisedTokens: ['i', 'walk', 'in', 'favour'],
            keyterms: ['favour'],
          ),
          const PhraseSpec(
            raw: 'favour is my portion',
            normalisedTokens: ['favour', 'is', 'my', 'portion'],
            keyterms: ['favour'],
          ),
        ]),
      );

      expect(uri.queryParametersAll['keyterm'], ['favour']);
    });

    test('no phrase means no keyterm at all', () {
      final uri = DeepgramSocket.buildUri(phrases: null);

      expect(uri.queryParametersAll.containsKey('keyterm'), isFalse);
      expect(uri.queryParameters['language'], 'en');
    });
  });

  group('credentials', () {
    // Checked against the live API on 2 Oct 2026: a temporary token sent as
    // `Token` is refused with 401 "Invalid credentials", and connects as
    // `Bearer`. Every session bought through the voice service carries a
    // temporary token, so getting this wrong refuses all of them — while dev
    // builds, which hold an API key, keep working.
    test('a temporary token is presented as Bearer', () {
      expect(
        DeepgramSocket.authorizationHeader(
          const SpeechCredential.temporaryToken('jwt.value.here'),
        ),
        'Bearer jwt.value.here',
      );
    });

    test('an API key is presented as Token', () {
      expect(
        DeepgramSocket.authorizationHeader(
          const SpeechCredential.apiKey('0123abcd'),
        ),
        'Token 0123abcd',
      );
    });

    test('connect sends the header for the kind it was given', () async {
      final seen = <String>[];
      for (final credential in const [
        SpeechCredential.temporaryToken('jwt'),
        SpeechCredential.apiKey('key'),
      ]) {
        final socket = DeepgramSocket();
        try {
          await socket.connect(
            credential: credential,
            channelFactory: (uri, headers) {
              seen.add(headers['Authorization'] as String);
              return _RefusedChannel();
            },
          );
        } on WebSocketChannelException {
          // The channel refuses on purpose; only the header matters here.
        }
        await socket.dispose();
      }

      expect(seen, ['Bearer jwt', 'Token key']);
    });

    test('a credential never prints its value', () {
      expect(
        const SpeechCredential.temporaryToken('secret-jwt').toString(),
        isNot(contains('secret-jwt')),
      );
    });
  });

  group('a refused handshake', () {
    // A channel that was never opened never completes its close. Awaiting
    // that unbounded froze the whole start: the engine was waiting on the
    // disposal of a socket that could not connect, so the failure was never
    // reported and the app sat on "Connecting…" with a greyed-out button.
    Future<DeepgramSocket> refused() async {
      final socket = DeepgramSocket();
      await expectLater(
        socket.connect(
          credential: const SpeechCredential.temporaryToken('jwt'),
          channelFactory: (_, _) => _RefusedChannel(),
        ),
        throwsA(isA<WebSocketChannelException>()),
      );
      return socket;
    }

    test('reports the error state and says why', () async {
      final socket = await refused();

      expect(socket.currentState, SocketState.error);
      expect(socket.closeDescription, contains('Could not connect'));
      await socket.dispose();
    });

    test('dispose returns even though the channel never closes', () async {
      final socket = await refused();

      await socket.dispose().timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('dispose never returned'),
      );
    });

    test('closeGracefully returns too', () async {
      final socket = await refused();

      await socket
          .closeGracefully(drainTimeoutMs: 0)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail('closeGracefully never returned'),
          );
      expect(socket.currentState, SocketState.disconnected);
      await socket.dispose();
    });
  });
}

/// What `IOWebSocketChannel` is like after the server refuses the upgrade:
/// `ready` fails, and closing the sink never completes.
class _RefusedChannel implements WebSocketChannel {
  @override
  Future<void> get ready => Future.error(
    WebSocketChannelException('was not upgraded to websocket, HTTP 401'),
  );

  @override
  WebSocketSink get sink => _NeverClosingSink();

  @override
  Stream<dynamic> get stream => const Stream.empty();

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NeverClosingSink implements WebSocketSink {
  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      Completer<void>().future;

  @override
  void add(dynamic data) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
