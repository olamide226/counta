import 'package:flutter/foundation.dart';

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

  /// RevenueCat's public SDK keys, one per store. Public by design: they can
  /// list products and start purchases, and nothing else.
  static const String _revenueCatIosKey = String.fromEnvironment(
    'REVENUECAT_IOS_KEY',
  );
  static const String _revenueCatAndroidKey = String.fromEnvironment(
    'REVENUECAT_ANDROID_KEY',
  );

  /// The key for the store this device buys from, or empty when there is
  /// none — no packs are offered then, and codes still work.
  static String get revenueCatKey => switch (defaultTargetPlatform) {
    TargetPlatform.iOS => _revenueCatIosKey,
    TargetPlatform.android => _revenueCatAndroidKey,
    _ => '',
  };

  /// False when the build was made without Supabase defines; the app then runs
  /// tap-only and skips backend initialisation instead of crashing.
  static bool get hasSupabase =>
      supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty;
}
