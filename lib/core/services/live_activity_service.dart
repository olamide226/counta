import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:live_activities/live_activities.dart';

/// Service managing iOS Live Activity / Dynamic Island state during active counting sessions.
class LiveActivityService {
  final LiveActivities _liveActivities;
  String? _activityId;
  DateTime? _lastUpdateTime;
  Map<String, dynamic>? _pendingData;
  Timer? _throttleTimer;

  static const String appGroupId = 'group.com.ruach-tech.counta';
  static const Duration updateThrottle = Duration(milliseconds: 1500);

  LiveActivityService({LiveActivities? liveActivities})
      : _liveActivities = liveActivities ?? LiveActivities();

  /// Initialize LiveActivities (registers App Group if supported).
  Future<void> init() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _liveActivities.init(appGroupId: appGroupId);
    } catch (e) {
      debugPrint('LiveActivityService init failed: $e');
    }
  }

  /// Start a Live Activity when a session begins.
  Future<void> startActivity({
    required String phrase,
    required int count,
    required int voiceCount,
    required int manualCount,
    required String status,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;

    final data = <String, dynamic>{
      'phrase': phrase.isEmpty ? 'Tap Session' : phrase,
      'count': count,
      'voiceCount': voiceCount,
      'manualCount': manualCount,
      'status': status,
    };

    try {
      // Clean up any existing activity first
      await endActivity();

      // iOSEnableRemoteUpdates defaults to true, which makes the plugin request
      // a push token. That requires the Push Notifications capability and fails
      // with ActivityKit.ActivityInput error 0 without it. Counta updates the
      // activity locally from updateActivity(), so no APNs round trip is needed.
      _activityId = await _liveActivities.createActivity(
        'counta_active_session',
        data,
        removeWhenAppIsKilled: true,
        iOSEnableRemoteUpdates: false,
      );

      _lastUpdateTime = DateTime.now();
      debugPrint('Live Activity started with id: $_activityId');
    } catch (e) {
      debugPrint('Failed to start Live Activity: $e');
    }
  }

  /// Request an update to the Live Activity (throttled to avoid ActivityKit rate limits).
  void updateActivity({
    required String phrase,
    required int count,
    required int voiceCount,
    required int manualCount,
    required String status,
    bool force = false,
  }) {
    if (defaultTargetPlatform != TargetPlatform.iOS || _activityId == null) {
      return;
    }

    final data = <String, dynamic>{
      'phrase': phrase.isEmpty ? 'Tap Session' : phrase,
      'count': count,
      'voiceCount': voiceCount,
      'manualCount': manualCount,
      'status': status,
    };

    final now = DateTime.now();
    if (force ||
        _lastUpdateTime == null ||
        now.difference(_lastUpdateTime!) >= updateThrottle) {
      _throttleTimer?.cancel();
      _throttleTimer = null;
      _sendUpdate(data);
    } else {
      _pendingData = data;
      _throttleTimer ??= Timer(
        updateThrottle - now.difference(_lastUpdateTime!),
        () {
          _throttleTimer = null;
          if (_pendingData != null) {
            final nextData = _pendingData!;
            _pendingData = null;
            _sendUpdate(nextData);
          }
        },
      );
    }
  }

  Future<void> _sendUpdate(Map<String, dynamic> data) async {
    if (_activityId == null) return;
    try {
      _lastUpdateTime = DateTime.now();
      await _liveActivities.updateActivity(_activityId!, data);
    } catch (e) {
      debugPrint('Failed to update Live Activity: $e');
    }
  }

  /// End the current Live Activity.
  Future<void> endActivity() async {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _pendingData = null;

    if (defaultTargetPlatform != TargetPlatform.iOS) return;

    if (_activityId != null) {
      final id = _activityId!;
      _activityId = null;
      try {
        await _liveActivities.endActivity(id);
        debugPrint('Live Activity ended: $id');
      } catch (e) {
        debugPrint('Failed to end Live Activity: $e');
      }
    }
  }
}
