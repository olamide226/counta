import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the screen awake while Settings → Keep Screen On is switched on.
///
/// Off, the phone's own auto-lock applies, and touching the screen resets it
/// as it does in any app. A voice session no longer needs the screen awake:
/// it survives a lock (the audio background mode on iOS, a microphone
/// foreground service on Android).
class ScreenWakeService {
  /// [toggle] exists so tests can exercise the acquire/release bookkeeping
  /// without standing up the plugin's platform channel.
  ScreenWakeService({Future<void> Function(bool enable)? toggle})
    : _toggle = toggle ?? _defaultToggle;

  final Future<void> Function(bool enable) _toggle;

  static Future<void> _defaultToggle(bool enable) =>
      enable ? WakelockPlus.enable() : WakelockPlus.disable();

  bool _held = false;

  @visibleForTesting
  bool get isHeld => _held;

  /// Requests that the screen stay on. Safe to call repeatedly.
  Future<void> acquire() async {
    if (_held) return;
    _held = true;
    try {
      await _toggle(true);
    } catch (e) {
      // Not fatal: the screen just follows the phone's own auto-lock.
      _held = false;
      debugPrint('Could not keep screen awake: $e');
    }
  }

  /// Releases the wakelock. Safe to call when it was never acquired.
  Future<void> release() async {
    if (!_held) return;
    _held = false;
    try {
      await _toggle(false);
    } catch (e) {
      debugPrint('Could not release screen wakelock: $e');
    }
  }

  /// Mirrors the wakelock to whether a session is active.
  Future<void> setActive(bool active) => active ? acquire() : release();

  void dispose() {
    // Fire and forget: the app is going away, but leaving a wakelock held
    // would keep the user's screen on after they are done.
    release();
  }
}
