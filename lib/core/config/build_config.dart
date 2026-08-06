import 'package:flutter/foundation.dart';

/// Single source of truth for what a build is allowed to expose.
///
/// Keeps the Dart-side gate aligned with the native display name set in
/// `ios/Flutter/*.xcconfig` and `android/app/src/debug/AndroidManifest.xml`,
/// so a build that calls itself "Counta Dev" is exactly the build that shows
/// developer tooling.
class BuildConfig {
  const BuildConfig._();

  /// True for debug and profile builds, false for release.
  static const bool isDev = kDebugMode || kProfileMode;

  /// Name shown in the app bar. Mirrors the native launcher name.
  static const String appName = isDev ? 'Counta Dev' : 'Counta';

  /// Whether developer-only screens (the streaming spike, raw latency
  /// read-outs, API key entry) are reachable from the UI.
  ///
  /// These surface a Deepgram key and raw transcripts, so they must never ship
  /// in a release build.
  static const bool showDebugTools = isDev;
}
