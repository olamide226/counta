import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/repositories/session_checkpoint_repository.dart';
import '../../domain/counting/counting_engine.dart';
import '../../domain/models/count_session.dart';
import '../../domain/models/session_record.dart';
import 'counter_provider.dart';
import 'hive_providers.dart';
import 'session_controller.dart';
import 'settings_provider.dart';

/// Builds the record that describes the session in progress right now.
///
/// Everything the controller does not know (settings snapshot, threshold,
/// session start) is filled in by the caller, so the checkpointer itself
/// stays free of provider lookups and is testable with a plain closure.
///
/// Called once per tracked session and again only when the active phrase
/// changes — the rest of what it returns cannot change while a session runs.
typedef CheckpointSnapshot =
    CountSession Function(SessionController controller, String id);

/// Writes the live count to [SessionCheckpointStore] so a crash mid-session
/// can be recovered on the next launch (requirements 7.2 and 7.3).
///
/// A session counts as active while it has unsaved progress: either a voice
/// engine is running, or the total is above zero. The first moment a session
/// becomes active is written immediately; after that a write happens at most
/// once per [interval], and only when the *persisted* content actually
/// changed. Engine status is not persisted, so status churn on its own —
/// connecting, reconnecting, degraded — never costs a write.
///
/// While nothing is happening there is no timer at all: the interval timer is
/// armed by the first unwritten change and clears itself once it fires.
///
/// Clearing is unconditional: `sessionStartupProvider` has already taken any
/// leftover from a previous process out of the store before this is attached,
/// so the only checkpoint it can ever see is its own.
class SessionCheckpointer {
  static const defaultInterval = Duration(seconds: 10);

  final SessionController _controller;
  final SessionCheckpointStore _store;
  final CheckpointSnapshot _snapshot;
  final Duration interval;
  final String Function() _newId;
  final DateTime Function() _now;

  Timer? _timer;
  String? _checkpointId;

  /// The cached immutable frame of the record, and the phrase it was built
  /// for. Rebuilt when the phrase changes, because a tap session can turn into
  /// a voice session without ever going inactive.
  CountSession? _base;
  PhraseSpec? _basePhrase;

  /// Fingerprint of the content last handed to the store. A change here is the
  /// only thing that justifies another write.
  String? _lastWritten;
  bool _dirty = false;

  SessionCheckpointer({
    required SessionController controller,
    required SessionCheckpointStore store,
    required CheckpointSnapshot snapshot,
    this.interval = defaultInterval,
    String Function()? newId,
    DateTime Function()? now,
  }) : _controller = controller,
       _store = store,
       _snapshot = snapshot,
       _newId = newId ?? const Uuid().v4,
       _now = now ?? DateTime.now {
    _controller.addListener(_onControllerChanged);
  }

  /// Whether a session with unsaved progress is being tracked.
  ///
  /// The checkpoint id is the one piece of state that says so; the timer is an
  /// implementation detail that comes and goes within a tracked session.
  bool get isTracking => _checkpointId != null;

  /// Identifier the current session's checkpoint is written under. Stable for
  /// the life of the session so a recovered record does not change identity
  /// between writes.
  String? get checkpointId => _checkpointId;

  bool get _isActive => _controller.isVoiceActive || _controller.total > 0;

  /// Everything that reaches the store, and nothing that does not.
  String _signature() {
    final phrase = _controller.activePhrase?.raw ?? '';
    return '${_controller.total}|${_controller.voiceCount}'
        '|${_controller.manualCount}|$phrase';
  }

  void _onControllerChanged() {
    if (!_isActive) {
      if (isTracking) _stopTracking();
      return;
    }

    if (!isTracking) {
      _startTracking();
      return;
    }

    // Status-only churn lands here and stops: the fingerprint is unchanged, so
    // there is nothing new to persist and no timer to arm.
    if (_signature() == _lastWritten) return;

    _dirty = true;
    _armTimer();
  }

  void _startTracking() {
    _checkpointId = _newId();
    _base = null;
    _basePhrase = null;
    _lastWritten = null;
    unawaited(_write());
  }

  void _armTimer() {
    // One in flight at a time is what bounds writes to one per interval.
    if (_timer != null) return;
    _timer = Timer(interval, () {
      _timer = null;
      if (_dirty) unawaited(_write());
    });
  }

  void _stopTracking() {
    _timer?.cancel();
    _timer = null;
    _checkpointId = null;
    _base = null;
    _basePhrase = null;
    _lastWritten = null;
    _dirty = false;
    unawaited(_store.clear());
  }

  CountSession _record(String id) {
    final phrase = _controller.activePhrase;
    if (_base == null || _basePhrase != phrase) {
      _base = _snapshot(_controller, id);
      _basePhrase = phrase;
    }

    return _base!.copyWith(
      endedAt: _now(),
      finalCount: _controller.total,
      // Null keeps whatever the base holds, which is itself null for a
      // tap-only session — that is the distinction the history screen reads.
      voiceCount: phrase == null ? null : _controller.voiceCount,
      manualCount: phrase == null ? null : _controller.manualCount,
    );
  }

  Future<void> _write() async {
    final id = _checkpointId;
    if (id == null) return;
    _dirty = false;
    final record = _record(id);
    _lastWritten = _signature();
    await _store.write(record);
  }

  /// Forces a checkpoint now, regardless of the interval.
  Future<void> flush() => _write();

  /// Removes the checkpoint after the session has been saved.
  ///
  /// Tracking continues: if the user keeps counting, the next change writes a
  /// fresh checkpoint for the progress made since the save. The fingerprint is
  /// deliberately left in place, so merely stopping the engine afterwards does
  /// not re-checkpoint counts that are already in history.
  Future<void> clear() async {
    _dirty = false;
    await _store.clear();
  }

  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _timer?.cancel();
    _timer = null;
  }
}

/// Keeps the active session checkpointed for the life of the app.
///
/// Attached by `sessionStartupProvider`, never read directly by a screen: it
/// must not exist until the previous run's checkpoint has been taken out of
/// the store.
final sessionCheckpointerProvider = Provider<SessionCheckpointer>((ref) {
  // `.notifier` deliberately: watching the ChangeNotifier itself would
  // rebuild this provider (and re-attach the listener) on every count.
  final controller = ref.watch(sessionControllerProvider.notifier);
  final checkpointer = SessionCheckpointer(
    controller: controller,
    store: ref.watch(sessionCheckpointRepositoryProvider),
    snapshot: (controller, id) {
      final counter = ref.read(counterProvider);
      final phrase = controller.activePhrase;
      return buildSessionRecord(
        id: id,
        // The session's own label when it has one — a recovered session used
        // to come back as the literal string 'Recovered session'.
        mantra: counter.mantra ?? phrase?.raw ?? 'Session in progress',
        settings: ref.read(settingsProvider),
        counter: counter,
        phrase: phrase,
        voiceCount: controller.voiceCount,
        manualCount: controller.manualCount,
        endedAt: DateTime.now(),
        completed: false,
      );
    },
  );
  ref.onDispose(checkpointer.dispose);
  return checkpointer;
});
