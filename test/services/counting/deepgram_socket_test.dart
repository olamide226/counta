import 'package:flutter_test/flutter_test.dart';
import 'package:counta/core/services/counting/deepgram_socket.dart';
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

      final uri = DeepgramSocket.buildUri(phrase: phrase);

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
  });
}
