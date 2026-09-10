import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/app_env.dart';
import '../../core/services/counting/block_client.dart';
import '../../domain/counting/block_service.dart';

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

/// The app's one route to the voice-block Edge Function.
///
/// Null when the build carries no Supabase configuration, which is what makes
/// a tap-only build (and every unit test) construct no HTTP client at all.
final blockServiceProvider = Provider<BlockService?>((ref) {
  if (!AppEnv.hasSupabase) return null;

  final client = BlockClient(
    functionUrl: Uri.parse('${AppEnv.supabaseUrl}/functions/v1/voice-block'),
    anonKey: AppEnv.supabasePublishableKey,
    accessToken: () async {
      // Waits for anonymous sign-in rather than racing it: a session started
      // in the first seconds of a cold launch would otherwise look signed out
      // and be refused a block it is entitled to.
      final session = await ref.read(supabaseSessionProvider.future);
      if (session == null) return null;
      if (!session.isExpired) return session.accessToken;

      // A long practice outlives an access token, so the credential is read
      // per request and refreshed here rather than captured at session start.
      try {
        final refreshed = await Supabase.instance.client.auth.refreshSession();
        return refreshed.session?.accessToken;
      } on AuthException catch (error) {
        debugPrint('Supabase session refresh failed: ${error.message}');
        return null;
      }
    },
  );
  ref.onDispose(client.dispose);
  return client;
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
