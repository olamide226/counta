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
    accessToken: () {
      final auth = Supabase.instance.client.auth;
      return resolveAccessToken(
        // Waits for anonymous sign-in rather than racing it: a session
        // started in the first seconds of a cold launch would otherwise look
        // signed out and be refused a block it is entitled to.
        startup: ref.read(supabaseSessionProvider.future),
        currentSession: () => auth.currentSession,
        refresh: () async => (await auth.refreshSession()).session,
        signInAnonymously: () async => (await auth.signInAnonymously()).session,
      );
    },
  );
  ref.onDispose(client.dispose);
  return client;
});

/// The JWT to send with a block request, read fresh on every one.
///
/// Goes through the same [resolveSupabaseSession] as startup, so there is one
/// answer to "what session are we on" rather than two that drift — the
/// closure this replaced returned null where the tested resolver signs back
/// in anonymously.
///
/// The *live* session is what it asks, not the snapshot startup resolved:
/// the SDK refreshes under us during an hour-long practice, and a snapshot's
/// `isExpired` latches true the moment its own `exp` passes, so reading it
/// sent every later acquire, release and renewal retry through a full
/// `refreshSession()` round trip.
/// [startup] is the future itself, not a thunk that makes one: there is a
/// single production call site and it already holds the provider's memoised
/// future. Awaiting it decides only whether this build has a backend at all —
/// the session to run with comes from [currentSession], and a null one there
/// signs back in like any other missing session rather than falling back to
/// the snapshot.
@visibleForTesting
Future<String?> resolveAccessToken({
  required Future<Session?> startup,
  required Session? Function() currentSession,
  required Future<Session?> Function() refresh,
  required Future<Session?> Function() signInAnonymously,
}) async {
  if (await startup == null) return null;

  final session = await resolveSupabaseSession(
    existing: currentSession(),
    refresh: refresh,
    signInAnonymously: signInAnonymously,
  );
  return session?.accessToken;
}

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
