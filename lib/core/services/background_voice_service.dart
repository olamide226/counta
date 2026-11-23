import 'dart:async';

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
/// The service's notification carries the live count. On Android 16+ it is a
/// Live Update: a chip in the status bar and a pinned card on the lock
/// screen, Android's counterpart of the iPhone Live Activity.
///
/// iOS needs nothing here: `UIBackgroundModes: audio` already keeps the
/// session alive there, so on every other platform this does nothing.
class BackgroundVoiceService {
  /// [start] and [stop] exist so tests can exercise the bookkeeping without
  /// the platform channel; [supported] defaults to "running on Android".
  BackgroundVoiceService({
    Future<bool> Function(String title, int count)? start,
    Future<void> Function(String title, int count)? update,
    Future<void> Function()? stop,
    bool? supported,
    this.updateInterval = const Duration(seconds: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _start = start ?? _platformStart,
       _update = update ?? _platformUpdate,
       _stop = stop ?? _platformStop,
       _supported =
           supported ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static const _channel = MethodChannel('com.ruachtech.counta/voice_session');

  static Future<bool> _platformStart(String title, int count) async =>
      await _channel.invokeMethod<bool>('start', {
        'title': title,
        'count': count,
      }) ??
      false;

  static Future<void> _platformUpdate(String title, int count) =>
      _channel.invokeMethod<void>('update', {'title': title, 'count': count});

  static Future<void> _platformStop() => _channel.invokeMethod<void>('stop');

  /// Whether this runs on Android, where all of this applies.
  bool get isAndroid => _supported;

  /// Whether Counta's counting notification can be a Live Update here. Off
  /// also when notifications as a whole are blocked for Counta, since
  /// nothing can show then.
  Future<LiveUpdates> liveUpdates() async {
    if (!_supported) return LiveUpdates.unsupported;
    try {
      final state = await _channel.invokeMethod<String>('liveUpdates');
      return LiveUpdates.values.firstWhere(
        (value) => value.name == state,
        orElse: () => LiveUpdates.unsupported,
      );
    } catch (e) {
      debugPrint('Could not read the Live Updates setting: $e');
      return LiveUpdates.unsupported;
    }
  }

  /// Opens the system switch for Counta's Live Updates. Android has no
  /// permission dialog for them; this page is the only way to turn them on.
  /// False when no settings page could be opened.
  Future<bool> openLiveUpdatesSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openLiveUpdatesSettings') ??
          false;
    } catch (e) {
      debugPrint('Could not open the Live Updates setting: $e');
      return false;
    }
  }

  final Future<bool> Function(String title, int count) _start;
  final Future<void> Function(String title, int count) _update;
  final Future<void> Function() _stop;
  final bool _supported;
  final DateTime Function() _now;

  /// The least time between two updates of the notification. Android drops
  /// updates an app posts faster than a few a second, which could leave a
  /// stale count showing; the latest one is always sent once it has passed.
  final Duration updateInterval;

  bool _held = false;
  bool _starting = false;

  /// When the platform last declined a start. Declines last a while (the
  /// microphone permission not granted yet), so asking again on every count
  /// would only repeat the refusal.
  DateTime? _declinedAt;

  /// What the notification shows, and what it should show next.
  (String, int)? _shown;
  (String, int)? _wanted;
  DateTime? _lastUpdate;
  Timer? _pending;

  /// Whether the service is running, so the background handler can skip the
  /// separate "counting" notification the service already shows.
  bool get isHeld => _held;

  /// Mirrors the service to whether a session is running. Safe to call on
  /// every status change: a start the platform declined (the microphone
  /// permission not granted yet) is simply asked for again next time.
  ///
  /// While it runs, [title] and [count] keep its notification current.
  Future<void> setActive(
    bool active, {
    required String title,
    required int count,
  }) => active ? _acquire(title, count) : _release();

  Future<void> _acquire(String title, int count) async {
    if (!_supported || _starting) return;
    if (_held) return _show((title, count));
    final declined = _declinedAt;
    if (declined != null && _now().difference(declined) < updateInterval) {
      return;
    }
    _starting = true;
    try {
      _held = await _start(title, count);
      if (_held) {
        _shown = (title, count);
        _lastUpdate = _now();
        _declinedAt = null;
      } else {
        _declinedAt = _now();
      }
    } catch (e) {
      // Not fatal: the session still counts while Counta is open.
      _declinedAt = _now();
      debugPrint('Could not keep voice counting alive in background: $e');
    } finally {
      _starting = false;
    }
  }

  Future<void> _show((String, int) wanted) async {
    _wanted = wanted;
    if (wanted == _shown || _pending != null) return;
    final last = _lastUpdate;
    final wait = last == null
        ? Duration.zero
        : updateInterval - _now().difference(last);
    if (wait > Duration.zero) {
      _pending = Timer(wait, () {
        _pending = null;
        final latest = _wanted;
        if (_held && latest != null) unawaited(_show(latest));
      });
      return;
    }
    _shown = wanted;
    _lastUpdate = _now();
    try {
      await _update(wanted.$1, wanted.$2);
    } catch (e) {
      debugPrint('Could not update the voice session notification: $e');
    }
  }

  Future<void> _release() async {
    if (!_supported || !_held) return;
    _held = false;
    _pending?.cancel();
    _pending = null;
    _shown = null;
    _wanted = null;
    _lastUpdate = null;
    _declinedAt = null;
    try {
      await _stop();
    } catch (e) {
      debugPrint('Could not stop the voice session service: $e');
    }
  }
}

/// Whether the counting notification can show as a Live Update.
enum LiveUpdates {
  /// Before Android 16, or not Android: an ordinary notification at most.
  unsupported,
  on,

  /// Supported, but the user's per-app switch is off.
  off,
}
