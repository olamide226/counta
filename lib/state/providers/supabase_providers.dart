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
  final existing = auth.currentSession;
  if (existing != null && !existing.isExpired) {
    return existing;
  }
  if (existing != null) {
    // Let the SDK refresh a persisted-but-stale session rather than minting a
    // second anonymous user for the same device.
    final refreshed = await auth.refreshSession();
    if (refreshed.session != null) return refreshed.session;
  }

  final response = await auth.signInAnonymously();
  return response.session;
});

/// The Supabase client, or null when the backend is not configured or has
/// not finished initialising. Consumers that need a JWT (the block client,
/// task 9) read this rather than touching [Supabase.instance] directly.
final supabaseClientProvider = Provider<SupabaseClient?>((ref) {
  final session = ref.watch(supabaseSessionProvider);
  return session.maybeWhen(
    data: (s) => s == null ? null : Supabase.instance.client,
    orElse: () => null,
  );
});
