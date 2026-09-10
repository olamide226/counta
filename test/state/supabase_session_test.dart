import 'dart:convert';

import 'package:counta/state/providers/supabase_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A structurally valid JWT, so `Session.isExpired` reads a real `exp` claim.
String _jwt(DateTime expiry) {
  String segment(Map<String, dynamic> claims) =>
      base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '');
  return '${segment({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${segment({'sub': 'user-1', 'exp': expiry.millisecondsSinceEpoch ~/ 1000})}.'
      'signature';
}

Session _session(DateTime expiry) => Session(
  accessToken: _jwt(expiry),
  tokenType: 'bearer',
  refreshToken: 'refresh-token',
  user: const User(
    id: 'user-1',
    appMetadata: {},
    userMetadata: {},
    aud: 'authenticated',
    createdAt: '2026-01-01T00:00:00Z',
    isAnonymous: true,
  ),
);

void main() {
  group('resolveSupabaseSession', () {
    test(
      'reuses a live persisted session without touching the network',
      () async {
        final live = _session(DateTime.now().add(const Duration(hours: 1)));

        final resolved = await resolveSupabaseSession(
          existing: live,
          refresh: () async => fail('must not refresh a live session'),
          signInAnonymously: () async => fail('must not sign in again'),
        );

        expect(resolved, same(live));
      },
    );

    test('refreshes a stale session rather than minting a new user', () async {
      final stale = _session(DateTime.now().subtract(const Duration(hours: 1)));
      final refreshed = _session(DateTime.now().add(const Duration(hours: 1)));

      final resolved = await resolveSupabaseSession(
        existing: stale,
        refresh: () async => refreshed,
        signInAnonymously: () async => fail('must not sign in again'),
      );

      expect(resolved, same(refreshed));
    });

    test('falls back to anonymous sign-in when the refresh throws', () async {
      // gotrue throws on a revoked or unreachable refresh; it does not return
      // a null session, so a fallback guarded only on null never ran.
      final stale = _session(DateTime.now().subtract(const Duration(hours: 1)));
      final fresh = _session(DateTime.now().add(const Duration(hours: 1)));

      final resolved = await resolveSupabaseSession(
        existing: stale,
        refresh: () async => throw AuthSessionMissingException(),
        signInAnonymously: () async => fresh,
      );

      expect(resolved, same(fresh));
    });

    test('falls back when the refresh resolves without a session', () async {
      final stale = _session(DateTime.now().subtract(const Duration(hours: 1)));
      final fresh = _session(DateTime.now().add(const Duration(hours: 1)));

      final resolved = await resolveSupabaseSession(
        existing: stale,
        refresh: () async => null,
        signInAnonymously: () async => fresh,
      );

      expect(resolved, same(fresh));
    });

    test('signs in anonymously when nothing is persisted', () async {
      final fresh = _session(DateTime.now().add(const Duration(hours: 1)));

      final resolved = await resolveSupabaseSession(
        existing: null,
        refresh: () async => fail('nothing to refresh'),
        signInAnonymously: () async => fresh,
      );

      expect(resolved, same(fresh));
    });
  });

  group('resolveAccessToken', () {
    test('reads the live session, not the startup snapshot', () async {
      // The snapshot startup resolved is fixed in time: once its own `exp`
      // passes, `isExpired` is true for ever. Reading it sent every acquire,
      // release and renewal retry of a long practice through a full
      // refreshSession() round trip, however fresh the SDK's session was.
      final snapshot = _session(
        DateTime.now().subtract(const Duration(hours: 1)),
      );
      final live = _session(DateTime.now().add(const Duration(hours: 1)));

      final token = await resolveAccessToken(
        startup: () async => snapshot,
        currentSession: () => live,
        refresh: () async => fail('the SDK has already refreshed'),
        signInAnonymously: () async => fail('there is a live session'),
      );

      expect(token, live.accessToken);
    });

    test('refreshes when the live session really has expired', () async {
      final stale = _session(DateTime.now().subtract(const Duration(hours: 1)));
      final refreshed = _session(DateTime.now().add(const Duration(hours: 1)));

      final token = await resolveAccessToken(
        startup: () async => stale,
        currentSession: () => stale,
        refresh: () async => refreshed,
        signInAnonymously: () async => fail('the refresh answered'),
      );

      expect(token, refreshed.accessToken);
    });

    test('a revoked refresh signs back in rather than giving up', () async {
      // The closure this replaced returned null here, so the block request
      // failed 401 in exactly the case the shared resolver recovers from.
      final stale = _session(DateTime.now().subtract(const Duration(hours: 1)));
      final fresh = _session(DateTime.now().add(const Duration(hours: 1)));

      final token = await resolveAccessToken(
        startup: () async => stale,
        currentSession: () => stale,
        refresh: () async => throw AuthSessionMissingException(),
        signInAnonymously: () async => fresh,
      );

      expect(token, fresh.accessToken);
    });

    test('a build with no backend session has no credential', () async {
      final token = await resolveAccessToken(
        startup: () async => null,
        currentSession: () => fail('nothing was signed in'),
        refresh: () async => fail('nothing to refresh'),
        signInAnonymously: () async => fail('startup already decided'),
      );

      expect(token, isNull);
    });
  });

  group('blockServiceProvider', () {
    test('a build with no Supabase configuration has no block service', () {
      // Voice counting is unavailable rather than half-wired: with no backend
      // there is nothing that could pay for streaming time, so no HTTP client
      // is built and the engine falls back to the dev-token path.
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(blockServiceProvider), isNull);
    });
  });
}
