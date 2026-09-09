/// Public, non-secret configuration baked in with `--dart-define` (see the
/// Makefile's `DART_DEFINES` and `.env.example`).
///
/// The Supabase URL and publishable key are safe to ship in a client binary:
/// the publishable key only grants what row-level security allows. Secrets
/// (the Deepgram master key, RevenueCat secret) live in Supabase function
/// secrets and never appear here.
class AppEnv {
  const AppEnv._();

  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');

  static const String supabasePublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );

  /// False when the build was made without Supabase defines; the app then runs
  /// tap-only and skips backend initialisation instead of crashing.
  static bool get hasSupabase =>
      supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty;
}
