import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps a voice session counting on Android while the phone is locked or
/// Counta is in the background.
///
/// Android stops an app's microphone once it leaves the foreground, and soon
/// kills the app, unless a foreground service of type `microphone` is
/// running. `VoiceSessionService` (android/app/.../VoiceSessionService.kt) is
/// that service; this class starts it while a session runs and stops it when
/// the session ends. Capture and streaming carry on in Dart unchanged.
///
/// iOS needs nothing here: `UIBackgroundModes: audio` already keeps the
/// session alive there, so on every other platform this does nothing.
class BackgroundVoiceService {
  /// [start] and [stop] exist so tests can exercise the bookkeeping without
  /// the platform channel; [supported] defaults to "running on Android".
  BackgroundVoiceService({
    Future<bool> Function(String title)? start,
    Future<void> Function()? stop,
    bool? supported,
  }) : _start = start ?? _platformStart,
       _stop = stop ?? _platformStop,
       _supported =
           supported ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static const _channel = MethodChannel('com.ruachtech.counta/voice_session');

  static Future<bool> _platformStart(String title) async =>
      await _channel.invokeMethod<bool>('start', {'title': title}) ?? false;

  static Future<void> _platformStop() => _channel.invokeMethod<void>('stop');

  final Future<bool> Function(String title) _start;
  final Future<void> Function() _stop;
  final bool _supported;

  bool _held = false;
  bool _starting = false;

  /// Whether the service is running, so the background handler can skip the
  /// separate "counting" notification the service already shows.
  bool get isHeld => _held;

  /// Mirrors the service to whether a session is running. Safe to call on
  /// every status change: a start the platform declined (the microphone
  /// permission not granted yet) is simply asked for again next time.
  Future<void> setActive(bool active, {required String title}) =>
      active ? _acquire(title) : _release();

  Future<void> _acquire(String title) async {
    if (!_supported || _held || _starting) return;
    _starting = true;
    try {
      _held = await _start(title);
    } catch (e) {
      // Not fatal: the session still counts while Counta is open.
      debugPrint('Could not keep voice counting alive in background: $e');
    } finally {
      _starting = false;
    }
  }

  Future<void> _release() async {
    if (!_supported || !_held) return;
    _held = false;
    try {
      await _stop();
    } catch (e) {
      debugPrint('Could not stop the voice session service: $e');
    }
  }
}
