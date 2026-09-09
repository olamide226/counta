import 'build_config.dart';

/// Developer-only credentials baked in with `--dart-define`.
///
/// The only place in the app that reads `DEEPGRAM_API_KEY`. Release builds
/// obtain a short-lived Deepgram token from the voice-block Edge Function
/// (task 8/9) and must never hold the master key, so every accessor here
/// throws unless [BuildConfig.showDebugTools] is on. Because that flag is a
/// compile-time constant, the release binary contains no live read of the
/// define at all.
class DevSecrets {
  const DevSecrets._();

  /// Deepgram master key for the Streaming Spike Debug screen and for running
  /// a voice session in a dev build before the block client exists.
  ///
  /// Null when no key was compiled in. "Empty define means no key" is decided
  /// here so every caller agrees on it rather than each re-checking `isEmpty`.
  static String? get deepgramApiKey {
    if (!BuildConfig.showDebugTools) {
      throw StateError('DevSecrets are not available in release builds');
    }
    const key = String.fromEnvironment('DEEPGRAM_API_KEY');
    return key.isEmpty ? null : key;
  }
}
