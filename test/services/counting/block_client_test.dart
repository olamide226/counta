import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:counta/core/services/counting/block_client.dart';
import 'package:counta/domain/counting/block_service.dart';

/// A recorded request, so the tests can assert what actually went out rather
/// than only what came back.
class _Sent {
  _Sent(this.request, this.body);
  final http.Request request;
  final Map<String, dynamic> body;
}

void main() {
  final functionUrl = Uri.parse(
    'https://project.supabase.co/functions/v1/voice-block',
  );
  const sessionId = '11111111-1111-4111-8111-111111111111';
  const blockId = '22222222-2222-4222-8222-222222222222';

  late List<_Sent> sent;

  /// Builds a client whose transport answers with [status] and [body] for
  /// every request, recording what it was asked.
  BlockClient clientAnswering(
    int status,
    Object? body, {
    Map<String, String> headers = const {},
    String? token = 'jwt-token',
  }) {
    return BlockClient(
      functionUrl: functionUrl,
      anonKey: 'publishable-key',
      accessToken: () async => token,
      httpClient: MockClient((request) async {
        sent.add(
          _Sent(
            request,
            request.body.isEmpty
                ? <String, dynamic>{}
                : jsonDecode(request.body) as Map<String, dynamic>,
          ),
        );
        return http.Response(
          body is String ? body : jsonEncode(body),
          status,
          headers: {'content-type': 'application/json', ...headers},
        );
      }),
    );
  }

  setUp(() => sent = <_Sent>[]);

  group('BlockClient.acquire', () {
    test('200 yields a block', () async {
      final client = clientAnswering(200, {
        'block_id': blockId,
        'token': 'dg-token',
        'block_seconds': 300,
        'expires_at': '2026-09-10T12:05:00.000Z',
        'balance_after': 34,
      });
      addTearDown(client.dispose);

      final block = await client.acquire(sessionId);

      expect(block.id, blockId);
      expect(block.deepgramToken, 'dg-token');
      expect(block.blockSeconds, 300);
      expect(block.balanceAfter, 34);
      expect(block.expiresAt.toUtc(), DateTime.utc(2026, 9, 10, 12, 5));

      // The grant is a POST to the function root carrying the session id, with
      // the caller's JWT — the renewal contract is keyed on that session id.
      expect(sent.single.request.method, 'POST');
      expect(sent.single.request.url, functionUrl);
      expect(sent.single.body, {'session_id': sessionId});
      expect(sent.single.request.headers['Authorization'], 'Bearer jwt-token');
      expect(sent.single.request.headers['apikey'], 'publishable-key');
    });

    test('402 carries the balance and what a block costs', () async {
      final client = clientAnswering(402, {
        'error': 'insufficient_credit',
        'balance': 2,
        'required': 5,
      });
      addTearDown(client.dispose);

      await expectLater(
        client.acquire(sessionId),
        throwsA(
          isA<BlockInsufficientCredit>()
              .having((e) => e.balance, 'balance', 2)
              .having((e) => e.required, 'required', 5),
        ),
      );
    });

    test('409 carries when the live block expires', () async {
      final client = clientAnswering(409, {
        'error': 'block_in_flight',
        'expires_at': '2026-09-10T12:05:00.000Z',
      });
      addTearDown(client.dispose);

      await expectLater(
        client.acquire(sessionId),
        throwsA(
          isA<BlockInFlight>().having(
            (e) => e.expiresAt?.toUtc(),
            'expiresAt',
            DateTime.utc(2026, 9, 10, 12, 5),
          ),
        ),
      );
    });

    test('401 is unauthenticated', () async {
      final client = clientAnswering(401, {'error': 'unauthenticated'});
      addTearDown(client.dispose);

      await expectLater(
        client.acquire(sessionId),
        throwsA(isA<BlockUnauthenticated>()),
      );
    });

    test('429 is rate limited and reads Retry-After', () async {
      final client = clientAnswering(
        429,
        {'error': 'rate_limited'},
        headers: {'retry-after': '120'},
      );
      addTearDown(client.dispose);

      await expectLater(
        client.acquire(sessionId),
        throwsA(
          isA<BlockRateLimited>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 120),
          ),
        ),
      );
    });

    test('429 reads the retry hint from the body too', () async {
      // The function states its window in the body, like every other field of
      // its contract; only the Supabase gateway sets the header. Reading just
      // the header left `retryAfter` permanently null against the function's
      // own 429, and the engine fell back to a delay inside the window it had
      // just been refused in.
      final client = clientAnswering(429, {
        'error': 'rate_limited',
        'retry_after': 90,
      });
      addTearDown(client.dispose);

      await expectLater(
        client.acquire(sessionId),
        throwsA(
          isA<BlockRateLimited>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 90),
          ),
        ),
      );
    });

    test('a 429 that names no window at all has no hint', () async {
      final client = clientAnswering(429, {'error': 'rate_limited'});
      addTearDown(client.dispose);

      await expectLater(
        client.acquire(sessionId),
        throwsA(
          isA<BlockRateLimited>().having(
            (e) => e.retryAfter,
            'retryAfter',
            isNull,
          ),
        ),
      );
    });

    test('503 is a provider outage', () async {
      final client = clientAnswering(503, {'error': 'provider_unavailable'});
      addTearDown(client.dispose);

      await expectLater(
        client.acquire(sessionId),
        throwsA(isA<BlockProviderUnavailable>()),
      );
    });

    test('400 is a rejected request carrying the server reason', () async {
      final client = clientAnswering(400, {'error': 'invalid_session_id'});
      addTearDown(client.dispose);

      await expectLater(
        client.acquire(sessionId),
        throwsA(
          isA<BlockRequestRejected>()
              .having((e) => e.status, 'status', 400)
              .having((e) => e.reason, 'reason', 'invalid_session_id'),
        ),
      );
    });

    test(
      'an undocumented status is rejected, never silently accepted',
      () async {
        final client = clientAnswering(500, {'error': 'internal'});
        addTearDown(client.dispose);

        await expectLater(
          client.acquire(sessionId),
          throwsA(
            isA<BlockRequestRejected>().having((e) => e.status, 's', 500),
          ),
        );
      },
    );

    test(
      'a transport failure surfaces as BlockUnreachable, not as http',
      () async {
        final client = BlockClient(
          functionUrl: functionUrl,
          accessToken: () async => 'jwt-token',
          httpClient: MockClient((_) async => throw const _Offline()),
        );
        addTearDown(client.dispose);

        await expectLater(
          client.acquire(sessionId),
          throwsA(
            isA<BlockUnreachable>().having(
              (e) => e.cause,
              'cause',
              isA<_Offline>(),
            ),
          ),
        );
      },
    );

    test('a sign-in that fails is unreachable, not a raw exception', () async {
      // Getting the token is a network call too. A dropped sign-in reached
      // the screen as "AuthRetryableFetchException(... Connection closed
      // before full header was received ...)".
      var requests = 0;
      final client = BlockClient(
        functionUrl: functionUrl,
        accessToken: () async => throw const _Offline(),
        httpClient: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      addTearDown(client.dispose);

      await expectLater(
        client.acquire(sessionId),
        throwsA(
          isA<BlockUnreachable>().having(
            (e) => e.cause,
            'cause',
            isA<_Offline>(),
          ),
        ),
      );
      // Nothing was sent: there was no token to send it with.
      expect(requests, 0);
    });

    test('a sign-in that never answers cannot hang the request', () async {
      final client = BlockClient(
        functionUrl: functionUrl,
        accessToken: () => Completer<String?>().future,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        timeout: const Duration(milliseconds: 50),
      );
      addTearDown(client.dispose);

      await expectLater(
        client
            .acquire(sessionId)
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () => fail('acquire never returned'),
            ),
        throwsA(isA<BlockUnreachable>()),
      );
    });

    test('a 200 that is not a grant is not treated as one', () async {
      final client = clientAnswering(200, {'block_id': blockId});
      addTearDown(client.dispose);

      await expectLater(
        client.acquire(sessionId),
        throwsA(isA<BlockUnreachable>()),
      );
    });

    test('no session means no request at all', () async {
      final client = clientAnswering(200, {}, token: null);
      addTearDown(client.dispose);

      await expectLater(
        client.acquire(sessionId),
        throwsA(isA<BlockUnauthenticated>()),
      );
      expect(sent, isEmpty);
    });
  });

  group('BlockClient.refreshToken', () {
    test('200 mints a credential against the same block', () async {
      final client = clientAnswering(200, {'token': 'dg-2', 'expires_in': 30});
      addTearDown(client.dispose);

      expect(await client.refreshToken(blockId), 'dg-2');

      expect(
        sent.single.request.url,
        Uri.parse('https://project.supabase.co/functions/v1/voice-block/token'),
      );
      expect(sent.single.body, {'block_id': blockId});
    });

    test('404 says the block is gone, not that the request was bad', () async {
      // The caller's answer differs: a rejected request is a client bug to
      // retry past, a dead block ends the session holding it.
      final client = clientAnswering(404, {'error': 'block_not_found'});
      addTearDown(client.dispose);

      await expectLater(
        client.refreshToken(blockId),
        throwsA(isA<BlockNotFound>()),
      );
    });

    test('429 is rate limited and reads Retry-After', () async {
      final client = clientAnswering(
        429,
        {'error': 'rate_limited'},
        headers: {'retry-after': '4'},
      );
      addTearDown(client.dispose);

      await expectLater(
        client.refreshToken(blockId),
        throwsA(
          isA<BlockRateLimited>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 4),
          ),
        ),
      );
    });

    for (final entry in <int, Matcher>{
      400: isA<BlockRequestRejected>(),
      401: isA<BlockUnauthenticated>(),
      503: isA<BlockProviderUnavailable>(),
    }.entries) {
      test('${entry.key} maps to its own failure type', () async {
        final client = clientAnswering(entry.key, {'error': 'nope'});
        addTearDown(client.dispose);

        await expectLater(client.refreshToken(blockId), throwsA(entry.value));
      });
    }

    test('a 200 with no token is not silently accepted', () async {
      final client = clientAnswering(200, {'expires_in': 30});
      addTearDown(client.dispose);

      await expectLater(
        client.refreshToken(blockId),
        throwsA(isA<BlockUnreachable>()),
      );
    });
  });

  group('BlockClient.release', () {
    test('reports usage to /release and returns the refund verdict', () async {
      final client = clientAnswering(200, {'refunded': true, 'balance': 39});
      addTearDown(client.dispose);

      final result = await client.release(
        blockId,
        streamedSecs: 12,
        detections: 0,
        eligibleForRefund: true,
      );

      expect(result.refunded, isTrue);
      expect(result.balance, 39);

      expect(
        sent.single.request.url,
        Uri.parse(
          'https://project.supabase.co/functions/v1/voice-block/release',
        ),
      );
      // `detections` is always present and honest: the server treats an absent
      // or non-integer count as no report at all, never as zero.
      expect(sent.single.body, {
        'block_id': blockId,
        'streamed_secs': 12,
        'detections': 0,
        'eligible_for_refund': true,
      });
    });

    test('a used block reports no refund and no balance', () async {
      final client = clientAnswering(200, {'refunded': false});
      addTearDown(client.dispose);

      final result = await client.release(
        blockId,
        streamedSecs: 280,
        detections: 96,
        eligibleForRefund: false,
      );

      expect(result.refunded, isFalse);
      expect(result.balance, isNull);
      expect(sent.single.body['detections'], 96);
      expect(sent.single.body['eligible_for_refund'], isFalse);
    });

    test('negative counts are clamped rather than sent as a 400', () async {
      final client = clientAnswering(200, {'refunded': false});
      addTearDown(client.dispose);

      await client.release(
        blockId,
        streamedSecs: -3,
        detections: -1,
        eligibleForRefund: false,
      );

      expect(sent.single.body['streamed_secs'], 0);
      expect(sent.single.body['detections'], 0);
    });

    test('400 invalid_detections is a rejected request', () async {
      final client = clientAnswering(400, {'error': 'invalid_detections'});
      addTearDown(client.dispose);

      await expectLater(
        client.release(
          blockId,
          streamedSecs: 1,
          detections: 0,
          eligibleForRefund: true,
        ),
        throwsA(
          isA<BlockRequestRejected>().having(
            (e) => e.reason,
            'reason',
            'invalid_detections',
          ),
        ),
      );
    });

    test('503 on release is a provider outage', () async {
      final client = clientAnswering(503, {'error': 'provider_unavailable'});
      addTearDown(client.dispose);

      await expectLater(
        client.release(
          blockId,
          streamedSecs: 1,
          detections: 0,
          eligibleForRefund: false,
        ),
        throwsA(isA<BlockProviderUnavailable>()),
      );
    });

    test('reports what the block cost and what came back', () async {
      // Stopping early returns the unused minutes, and the app tells the user
      // how many.
      final client = clientAnswering(200, {
        'refunded': true,
        'balance': 19,
        'used_credits': 1,
        'refunded_credits': 4,
      });
      addTearDown(client.dispose);

      final release = await client.release(
        blockId,
        streamedSecs: 37,
        detections: 4,
        eligibleForRefund: false,
      );

      expect(release.refunded, isTrue);
      expect(release.balance, 19);
      expect(release.usedCredits, 1);
      expect(release.refundedCredits, 4);
    });

    test('an older answer without the split still parses', () async {
      final client = clientAnswering(200, {'refunded': false});
      addTearDown(client.dispose);

      final release = await client.release(
        blockId,
        streamedSecs: 300,
        detections: 9,
        eligibleForRefund: false,
      );

      expect(release.usedCredits, isNull);
      expect(release.refundedCredits, isNull);
    });
  });

  group('BlockClient.readBalance', () {
    test('reads the balance and what a session needs', () async {
      final client = clientAnswering(200, {'balance': 23, 'required': 5});
      addTearDown(client.dispose);

      final balance = await client.readBalance();

      expect(balance.balance, 23);
      expect(balance.required, 5);
      expect(balance.canStart, isTrue);
      expect(sent.single.request.url.path, endsWith('/voice-block/balance'));
      expect(sent.single.request.headers['Authorization'], 'Bearer jwt-token');
    });

    test('too little to start is reported, not hidden', () async {
      final client = clientAnswering(200, {'balance': 3, 'required': 5});
      addTearDown(client.dispose);

      expect((await client.readBalance()).canStart, isFalse);
    });

    test('a 200 with no balance is not read as zero', () async {
      // Zero is a real answer with consequences: it tells someone they have
      // no minutes. A malformed body must not produce it.
      final client = clientAnswering(200, {'something': 'else'});
      addTearDown(client.dispose);

      await expectLater(client.readBalance(), throwsA(isA<BlockUnreachable>()));
    });

    test('429 is a rate limit', () async {
      final client = clientAnswering(429, {
        'error': 'rate_limited',
        'retry_after_seconds': 30,
      });
      addTearDown(client.dispose);

      await expectLater(client.readBalance(), throwsA(isA<BlockRateLimited>()));
    });
  });

  group('BlockClient.redeem', () {
    test('a good code reports what it added', () async {
      final client = clientAnswering(200, {
        'redeemed': true,
        'credits': 50,
        'balance': 50,
      });
      addTearDown(client.dispose);

      final outcome = await client.redeem('  spring24 ');

      expect(
        outcome,
        isA<VoucherRedeemed>()
            .having((o) => o.credits, 'credits', 50)
            .having((o) => o.balance, 'balance', 50),
      );
      expect(sent.single.request.url.path, endsWith('/voice-block/redeem'));
      // Trimmed: a code pasted with a trailing space is still that code.
      expect(sent.single.body, {'code': 'spring24'});
    });

    test('a code this user already used moves nothing', () async {
      final client = clientAnswering(200, {
        'redeemed': false,
        'reason': 'already_redeemed',
        'credits': 50,
      });
      addTearDown(client.dispose);

      expect(await client.redeem('SPRING24'), isA<VoucherAlreadyRedeemed>());
    });

    test('an unknown code is a refusal, not a missing block', () async {
      // 404 means "block gone" on the block routes and ends a session there.
      // Here it means "no such code", and must not be read as the other.
      final client = clientAnswering(404, {'error': 'voucher_invalid'});
      addTearDown(client.dispose);

      final outcome = await client.redeem('NOPE');

      expect(
        outcome,
        isA<VoucherRefused>().having(
          (o) => o.reason,
          'reason',
          VoucherRefusal.invalid,
        ),
      );
    });

    test('expired and used-up codes say which', () async {
      final expired = clientAnswering(409, {'error': 'voucher_expired'});
      addTearDown(expired.dispose);
      final usedUp = clientAnswering(409, {'error': 'voucher_exhausted'});
      addTearDown(usedUp.dispose);

      expect(
        (await expired.redeem('OLD') as VoucherRefused).reason,
        VoucherRefusal.expired,
      );
      expect(
        (await usedUp.redeem('FULL') as VoucherRefused).reason,
        VoucherRefusal.usedUp,
      );
    });

    test('too many wrong guesses is a rate limit, not a refusal', () async {
      final client = clientAnswering(429, {
        'error': 'rate_limited',
        'retry_after_seconds': 600,
      });
      addTearDown(client.dispose);

      await expectLater(
        client.redeem('GUESS'),
        throwsA(isA<BlockRateLimited>()),
      );
    });

    test('every refusal reads as a sentence for the person who typed it', () {
      for (final reason in VoucherRefusal.values) {
        final message = VoucherRefused(reason).message;
        expect(message, isNot(contains('voucher')));
        expect(message, endsWith('.'));
      }
    });
  });
}

/// Stands in for a socket that never connects.
class _Offline implements Exception {
  const _Offline();
}
