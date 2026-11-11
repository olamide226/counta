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

  /// Google OAuth client ids for signing in. The web client is the audience
  /// Supabase checks Google's tokens against; iOS also needs its own client.
  static const String googleWebClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
  );
  static const String googleIosClientId = String.fromEnvironment(
    'GOOGLE_IOS_CLIENT_ID',
  );

  /// Whether this build can offer "Continue with Google".
  static bool get hasGoogleSignIn =>
      googleWebClientId.isNotEmpty &&
      switch (defaultTargetPlatform) {
        TargetPlatform.android => true,
        TargetPlatform.iOS => googleIosClientId.isNotEmpty,
        _ => false,
      };

  /// Sign in with Apple is offered on iPhone, where it is native.
  static bool get hasAppleSignIn => defaultTargetPlatform == TargetPlatform.iOS;

  /// False when the build was made without Supabase defines; the app then runs
  /// tap-only and skips backend initialisation instead of crashing.
  static bool get hasSupabase =>
      supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty;
}
