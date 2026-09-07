import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/app_env.dart';

/// Initialises Supabase and signs the device in anonymously.
///
/// Resolves to the authenticated [Session], or null when the build carries no
/// Supabase configuration (tap-only builds, unit tests). Anonymous sign-in is
/// what gives the voice-block Edge Function a JWT subject to bill against; it
/// upgrades to a real account later without touching this provider.
///
/// Failures are reported through the provider's error state and never block
/// app startup: counting works offline and the voice feature surfaces the
/// problem when the user tries to start a session.
final supabaseSessionProvider = FutureProvider<Session?>((ref) async {
  if (!AppEnv.hasSupabase) {
    debugPrint('Supabase not configured; running without a backend session.');
    return null;
  }

  await Supabase.initialize(
    url: AppEnv.supabaseUrl,
    publishableKey: AppEnv.supabasePublishableKey,
  );

  final auth = Supabase.instance.client.auth;
  return resolveSupabaseSession(
    existing: auth.currentSession,
    refresh: () async => (await auth.refreshSession()).session,
    signInAnonymously: () async => (await auth.signInAnonymously()).session,
  );
});

/// Chooses the session to run with, given whatever the SDK has persisted.
///
/// A live persisted session is reused, and a stale one is refreshed rather
/// than replaced, so a device does not accumulate anonymous users (and orphan
/// the credit balance attached to the old one).
///
/// [refresh] throwing is the *normal* failure here, not a null return:
/// gotrue raises [AuthException] when the refresh token has been revoked,
/// expired or cannot be sent at all. Letting that escape stranded the provider
/// in a permanent error state with nothing to invalidate it, and made the
/// anonymous fallback below unreachable in exactly the cases it exists for.
@visibleForTesting
Future<Session?> resolveSupabaseSession({
  required Session? existing,
  required Future<Session?> Function() refresh,
  required Future<Session?> Function() signInAnonymously,
}) async {
  if (existing != null) {
    if (!existing.isExpired) return existing;
    try {
      final refreshed = await refresh();
      if (refreshed != null) return refreshed;
    } on AuthException catch (error) {
      debugPrint('Supabase session refresh failed: ${error.message}');
    }
  }
  return signInAnonymously();
}
