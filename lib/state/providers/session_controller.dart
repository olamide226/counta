import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../domain/counting/counting_engine.dart';
import '../../core/services/counting/tap_counting_engine.dart';
import '../../core/services/live_activity_service.dart';

/// Controller holding the authoritative local session count,
/// tracking voice count and manual count separately.
class SessionController extends ChangeNotifier {
  CountingEngine _engine;
  final LiveActivityService? _liveActivityService;
  StreamSubscription<CountEvent>? _countSubscription;
  StreamSubscription<EngineStatus>? _statusSubscription;
  StreamSubscription<String>? _diagnosticsSubscription;

  int _voiceCount = 0;
  int _manualCount = 0;
  EngineStatus _status = EngineStatus.idle;
  PhraseSpec? _activePhrase;
  DateTime? _sessionStart;
  String? _lastDiagnostic;

  SessionController({
    CountingEngine? engine,
    LiveActivityService? liveActivityService,
  }) : _engine = engine ?? TapCountingEngine(),
       _liveActivityService = liveActivityService {
    _attachEngineListeners();
  }

  int get total => _voiceCount + _manualCount;
  int get voiceCount => _voiceCount;
  int get manualCount => _manualCount;
  EngineStatus get status => _status;
  PhraseSpec? get activePhrase => _activePhrase;

  /// The most recent explanation of why voice counting degraded, if any.
  ///
  /// Cleared whenever a session starts or recovers, so the UI only shows it
  /// while something is actually wrong.
  String? get lastDiagnostic => _lastDiagnostic;

  /// Whether a voice session is currently running or trying to run.
  bool get isVoiceActive => const {
    EngineStatus.connecting,
    EngineStatus.live,
    EngineStatus.reconnecting,
    EngineStatus.degraded,
    EngineStatus.requestingBlock,
  }.contains(_status);

  Duration get elapsed {
    if (_sessionStart == null) return Duration.zero;
    return DateTime.now().difference(_sessionStart!);
  }

  CountingEngine get engine => _engine;

  void setEngine(CountingEngine newEngine) {
    _countSubscription?.cancel();
    _statusSubscription?.cancel();
    _diagnosticsSubscription?.cancel();
    _diagnosticsSubscription = null;
    _engine = newEngine;
    _attachEngineListeners();
  }

  void _attachEngineListeners() {
    _countSubscription = _engine.counts.listen(_handleCountEvent);
    _statusSubscription = _engine.status.listen(_handleStatusChange);
    _diagnosticsSubscription = _engine.diagnostics.listen((message) {
      _lastDiagnostic = message;
      notifyListeners();
    });
  }

  void _updateLiveActivity({bool force = false}) {
    if (!isVoiceActive) return;
    _liveActivityService?.updateActivity(
      phrase: _activePhrase?.raw ?? '',
      count: total,
      voiceCount: _voiceCount,
      manualCount: _manualCount,
      status: _status.name,
      force: force,
    );
  }

  void _handleCountEvent(CountEvent event) {
    // Manual events are deliberately ignored here: incrementManual() has
    // already counted them locally, so counting the echo would double up.
    if (event.source == CountSource.voice) {
      _voiceCount++;
    }
    _updateLiveActivity();
    notifyListeners();
  }

  void _handleStatusChange(EngineStatus newStatus) {
    // Recovering clears the warning, so a transient blip does not leave a
    // stale error banner sitting over a healthy session.
    if (newStatus == EngineStatus.live) {
      _lastDiagnostic = null;
    }
    _status = newStatus;
    _updateLiveActivity();
    notifyListeners();
  }

  /// Start or resume voice counting mid-session without wiping current count.
  Future<void> startSession([PhraseSpec? phrase]) async {
    final targetPhrase = phrase ?? _activePhrase;
    _activePhrase = targetPhrase;
    _lastDiagnostic = null;
    _sessionStart ??= DateTime.now();
    await _engine.start(targetPhrase);

    await _liveActivityService?.startActivity(
      phrase: targetPhrase?.raw ?? '',
      count: total,
      voiceCount: _voiceCount,
      manualCount: _manualCount,
      status: _status.name,
    );

    notifyListeners();
  }

  /// Manual increment from screen tap.
  void incrementManual() {
    _manualCount++;
    _engine.incrementManual();
    _updateLiveActivity();
    notifyListeners();
  }

  /// Manual decrement gesture with a floor of zero on total count.
  void decrementManual() {
    if (total <= 0) return;

    if (_manualCount > 0) {
      _manualCount--;
      _engine.decrementManual();
    } else if (_voiceCount > 0) {
      // Floor of total is enforced, if manual is 0 we decrement total via voice count adjustment
      _voiceCount--;
    }
    _updateLiveActivity();
    notifyListeners();
  }

  /// Seeds the running total when continuing a previously saved session.
  ///
  /// Without this the controller stays at zero while the UI shows the loaded
  /// count, and the next tap snaps the display back down to 1.
  void seed(int count, {DateTime? startedAt}) {
    _voiceCount = 0;
    _manualCount = count < 0 ? 0 : count;
    _activePhrase = null;
    _lastDiagnostic = null;
    _sessionStart = startedAt ?? DateTime.now();
    _updateLiveActivity();
    notifyListeners();
  }

  /// Reset the session counters.
  void reset({bool keepSessionStart = false}) {
    _voiceCount = 0;
    _manualCount = 0;
    if (!keepSessionStart) {
      _sessionStart = DateTime.now();
    }
    _updateLiveActivity(force: true);
    notifyListeners();
  }

  /// Stop the active session.
  Future<SessionSummary> stop() async {
    final summary = await _engine.stop();
    _status = EngineStatus.idle;
    await _liveActivityService?.endActivity();
    notifyListeners();
    return SessionSummary(
      voiceCount: _voiceCount,
      manualCount: _manualCount,
      totalCount: total,
      duration: summary.duration,
    );
  }

  @override
  void dispose() {
    _countSubscription?.cancel();
    _statusSubscription?.cancel();
    _diagnosticsSubscription?.cancel();
    _engine.dispose();
    super.dispose();
  }
}
