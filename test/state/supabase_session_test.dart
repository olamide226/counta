import 'dart:convert';

import 'package:counta/state/providers/supabase_providers.dart';
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
}
