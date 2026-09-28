import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../domain/counting/counting_engine.dart';
import '../../domain/models/count_session.dart';
import '../../domain/validation/phrase_validator.dart';
import '../../core/services/counting/tap_counting_engine.dart';
import '../../core/services/live_activity_service.dart';

/// Controller holding the authoritative local session count,
/// tracking voice count and manual count separately.
class SessionController extends ChangeNotifier {
  /// Statuses that mean the engine will never deliver a count. Reaching one of
  /// these while starting means the voice session did not happen.
  static const terminalStatuses = {
    EngineStatus.permissionDenied,
    EngineStatus.error,
    EngineStatus.exhausted,
  };

  CountingEngine _engine;
  final LiveActivityService? _liveActivityService;
  final CountingEngine Function() _voiceEngineFactory;
  final CountingEngine Function() _tapEngineFactory;

  /// Asks the user to accept the third-party audio disclosure, returning false
  /// when they decline. Set by the app shell, which owns the navigator the
  /// sheet needs — the controller must not reach into the UI layer itself.
  ///
  /// Null means no gate, which is what tests and the dev-only debug screen
  /// want.
  Future<bool> Function()? disclosureGate;
  StreamSubscription<CountEvent>? _countSubscription;
  StreamSubscription<EngineStatus>? _statusSubscription;
  StreamSubscription<String>? _diagnosticsSubscription;

  int _voiceCount = 0;
  int _manualCount = 0;
  EngineStatus _status = EngineStatus.idle;
  PhraseSet? _activePhrases;

  /// [_voiceCount] split by the phrase that matched. Kept summing to
  /// [_voiceCount] through every path that changes it, undo included, so the
  /// breakdown a user sees afterwards never disagrees with their total.
  final Map<String, int> _voiceCountsByPhrase = {};

  /// Most recent phrase a voice count landed on, so undoing a voice count
  /// takes it back off the phrase that earned it.
  String? _lastVoicePhrase;
  DateTime? _sessionStart;
  String? _lastDiagnostic;

  SessionController({
    CountingEngine? engine,
    LiveActivityService? liveActivityService,
    CountingEngine Function()? voiceEngineFactory,
    CountingEngine Function()? tapEngineFactory,
    this.disclosureGate,
  }) : _engine = engine ?? TapCountingEngine(),
       _liveActivityService = liveActivityService,
       // Defaulting the voice factory to the tap engine keeps a controller
       // built without wiring harmless: it can never open a microphone by
       // accident. The provider injects the real factories.
       _voiceEngineFactory = voiceEngineFactory ?? TapCountingEngine.new,
       _tapEngineFactory = tapEngineFactory ?? TapCountingEngine.new {
    _attachEngineListeners();
  }

  int get total => _voiceCount + _manualCount;
  int get voiceCount => _voiceCount;
  int get manualCount => _manualCount;
  EngineStatus get status => _status;
  PhraseSet? get activePhrases => _activePhrases;

  Map<String, int> get voiceCountsByPhrase =>
      Map.unmodifiable(_voiceCountsByPhrase);

  /// The phrase the latest voice count landed on, so the UI can show which
  /// phrase was just heard.
  String? get lastVoicePhrase => _lastVoicePhrase;

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
    final previous = _engine;
    if (identical(previous, newEngine)) return;

    _countSubscription?.cancel();
    _statusSubscription?.cancel();
    _diagnosticsSubscription?.cancel();
    _diagnosticsSubscription = null;
    _engine = newEngine;
    _attachEngineListeners();

    // The outgoing engine still holds a microphone, a socket and three stream
    // controllers. Dropping the reference without disposing leaked all of them
    // for the life of the app, once per voice session.
    unawaited(previous.dispose());
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
      phrase: _activePhrases?.label ?? '',
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
      final phrase = event.phrase ?? _activePhrases?.primary.raw;
      if (phrase != null) {
        _voiceCountsByPhrase.update(
          phrase,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        _lastVoicePhrase = phrase;
      }
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
  Future<void> startSession([PhraseSet? phrases]) async {
    final targetPhrases = phrases ?? _activePhrases;
    _activePhrases = targetPhrases;
    _lastDiagnostic = null;
    _sessionStart ??= DateTime.now();
    await _engine.start(targetPhrases);

    // Only mirror a session that is actually running. Checking one failure
    // status missed the rest — an errored or exhausted start left a Live
    // Activity on the lock screen for a session that was never counting.
    if (isVoiceActive) {
      await _liveActivityService?.startActivity(
        phrase: targetPhrases?.label ?? '',
        count: total,
        voiceCount: _voiceCount,
        manualCount: _manualCount,
        status: _status.name,
      );
    }

    notifyListeners();
  }

  /// Starts voice counting: shows the disclosure if it is still owed, installs
  /// a voice engine, and hands the session back to the tap engine if the
  /// engine cannot run.
  ///
  /// Returns the status the attempt ended at — [EngineStatus.idle] when the
  /// user declined the disclosure, [EngineStatus.live] on success, or the
  /// terminal status that stopped it. The screen reads that instead of asking
  /// the controller afterwards, because by then the failed session has already
  /// been rolled back.
  Future<EngineStatus> startVoiceSession(PhraseSet phrases) async {
    // Before the engine exists, not after: declining must not leave a
    // microphone stack built and a phrase marked active.
    final gate = disclosureGate;
    if (gate != null && !await gate()) return EngineStatus.idle;

    final previousPhrases = _activePhrases;
    final previousStart = _sessionStart;

    setEngine(_voiceEngineFactory());
    await startSession(phrases);

    final outcome = _status;
    if (!terminalStatuses.contains(outcome)) return outcome;

    // The engine will not deliver counts, so this session never started.
    // Rolling the frame back matters: leaving the phrase set meant the next
    // tap-only session was saved as a voice session with a start time from
    // the failed attempt.
    _activePhrases = previousPhrases;
    _sessionStart = previousStart;
    setEngine(_tapEngineFactory());
    _status = EngineStatus.idle;
    notifyListeners();
    return outcome;
  }

  /// Ends voice counting and hands the session back to the tap engine.
  Future<SessionSummary> stopVoiceSession() async {
    try {
      return await stop();
    } finally {
      // Even if teardown complained: the app must never be left holding a
      // dead cloud engine.
      setEngine(_tapEngineFactory());
    }
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
      _takeBackVoiceCount();
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
    _clearPhraseCounts();
    _manualCount = count < 0 ? 0 : count;
    _activePhrases = null;
    _lastDiagnostic = null;
    _sessionStart = startedAt ?? DateTime.now();
    _updateLiveActivity();
    notifyListeners();
  }

  /// Restores a session that was saved or recovered from a checkpoint.
  ///
  /// Unlike [seed] this keeps the session whole: the voice/tap split, the
  /// phrase that was being chanted and the original start time all come back,
  /// so continuing a recovered voice session does not silently turn it into a
  /// tap session that started just now.
  void restore(CountSession session) {
    final phrases = session.allPhrases;
    _voiceCount = (session.voiceCount ?? 0).clamp(0, session.finalCount);
    _manualCount = session.manualCount ?? (session.finalCount - _voiceCount);
    if (_manualCount < 0) _manualCount = 0;

    // Stored phrases are just raw text; re-normalising them here is what
    // makes the resumed session countable again rather than decorative.
    //
    // Taken one at a time rather than through `validateSet`: recovering a
    // crashed session should salvage what it can, and that returns nothing at
    // all if a single stored phrase no longer passes the current rules.
    final validator = PhraseValidator();
    final specs = [
      for (final phrase in phrases)
        if (validator.validate(phrase).phraseSpec case final spec?) spec,
    ];
    _activePhrases = specs.isEmpty ? null : PhraseSet(specs);

    _clearPhraseCounts();
    final stored = session.phraseCounts;
    if (stored != null) {
      _voiceCountsByPhrase.addAll(stored);
    } else if (_voiceCount > 0 && phrases.length == 1) {
      // A record from before the split was stored: with one phrase there is
      // only one place its voice counts can have come from.
      _voiceCountsByPhrase[phrases.single] = _voiceCount;
    }
    _lastDiagnostic = null;
    _sessionStart = session.startedAt;
    _updateLiveActivity();
    notifyListeners();
  }

  /// Reset the session counters.
  void reset({bool keepSessionStart = false}) {
    _voiceCount = 0;
    _clearPhraseCounts();
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
      voiceCountsByPhrase: voiceCountsByPhrase,
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

  void _clearPhraseCounts() {
    _voiceCountsByPhrase.clear();
    _lastVoicePhrase = null;
  }

  /// Removes one voice count from the per-phrase split, matching the one just
  /// taken off [_voiceCount].
  ///
  /// The phrase that earned the latest count gives it back; once that is
  /// spent, the largest remaining one does. Either way the split keeps
  /// summing to the total.
  void _takeBackVoiceCount() {
    var phrase = _lastVoicePhrase;
    if (phrase == null || (_voiceCountsByPhrase[phrase] ?? 0) <= 0) {
      phrase = null;
      var largest = 0;
      for (final entry in _voiceCountsByPhrase.entries) {
        if (entry.value > largest) {
          largest = entry.value;
          phrase = entry.key;
        }
      }
    }
    if (phrase == null) return;

    final remaining = _voiceCountsByPhrase[phrase]! - 1;
    if (remaining > 0) {
      _voiceCountsByPhrase[phrase] = remaining;
    } else {
      _voiceCountsByPhrase.remove(phrase);
      if (_lastVoicePhrase == phrase) _lastVoicePhrase = null;
    }
  }
}
