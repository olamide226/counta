import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/repositories/session_checkpoint_repository.dart';
import '../../domain/counting/counting_engine.dart';
import '../../domain/models/count_session.dart';
import 'counter_provider.dart';
import 'hive_providers.dart';
import 'session_controller.dart';
import 'settings_provider.dart';

/// Builds the record that describes the session in progress right now.
///
/// Everything the controller does not know (settings snapshot, threshold,
/// session start) is filled in by the caller, so the checkpointer itself
/// stays free of provider lookups and is testable with a plain closure.
typedef CheckpointSnapshot =
    CountSession Function(SessionController controller, String id);

/// Writes the live count to [SessionCheckpointStore] so a crash mid-session
/// can be recovered on the next launch (requirements 7.2 and 7.3).
///
/// A session counts as active while it has unsaved progress: either a voice
/// engine is running, or the total is above zero. While active, the count is
/// checkpointed at least every [interval] and immediately on every engine
/// status transition. When the session goes inactive (reset, new session) the
/// checkpoint is cleared. Saving must call [clear] explicitly, because saving
/// does not zero the on-screen count.
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

  Timer? _timer;
  String? _checkpointId;
  EngineStatus? _lastStatus;
  bool _dirty = false;

  SessionCheckpointer({
    required SessionController controller,
    required SessionCheckpointStore store,
    required CheckpointSnapshot snapshot,
    this.interval = defaultInterval,
    String Function()? newId,
  }) : _controller = controller,
       _store = store,
       _snapshot = snapshot,
       _newId = newId ?? const Uuid().v4 {
    _controller.addListener(_onControllerChanged);
  }

  /// Whether a session with unsaved progress is being tracked.
  bool get isTracking => _timer != null;

  /// Identifier the current session's checkpoint is written under. Stable for
  /// the life of the session so a recovered record does not change identity
  /// between writes.
  String? get checkpointId => _checkpointId;

  bool get _isActive => _controller.isVoiceActive || _controller.total > 0;

  void _onControllerChanged() {
    final status = _controller.status;
    final statusChanged = status != _lastStatus;
    _lastStatus = status;

    if (!_isActive) {
      if (_timer != null) _stopTracking();
      return;
    }

    if (_timer == null) {
      _startTracking();
      return;
    }

    if (statusChanged) {
      unawaited(_write());
    } else {
      _dirty = true;
    }
  }

  void _startTracking() {
    _checkpointId = _newId();
    _timer = Timer.periodic(interval, (_) {
      if (_dirty) unawaited(_write());
    });
    unawaited(_write());
  }

  void _stopTracking() {
    _timer?.cancel();
    _timer = null;
    _checkpointId = null;
    _dirty = false;
    unawaited(_store.clear());
  }

  Future<void> _write() async {
    final id = _checkpointId;
    if (id == null) return;
    _dirty = false;
    await _store.write(_snapshot(_controller, id));
  }

  /// Forces a checkpoint now, regardless of the interval.
  Future<void> flush() => _write();

  /// Removes the checkpoint after the session has been saved.
  ///
  /// Tracking continues: if the user keeps counting, the next dirty tick
  /// writes a fresh checkpoint for the progress made since the save.
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
/// Attached by [sessionStartupProvider], never read directly by a screen: it
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
      final settings = ref.read(settingsProvider);
      final counter = ref.read(counterProvider);
      final phrase = controller.activePhrase;
      return CountSession(
        id: id,
        mantra: phrase?.raw ?? 'Recovered session',
        startedAt: counter.sessionStart,
        endedAt: DateTime.now(),
        finalCount: controller.total,
        threshold: counter.threshold,
        repeatInterval: counter.repeatInterval,
        soundMode: settings.soundMode,
        themeModeChoice: settings.themeModeChoice,
        themeId: settings.themeId,
        phrase: phrase?.raw,
        voiceCount: phrase != null ? controller.voiceCount : null,
        manualCount: phrase != null ? controller.manualCount : null,
        completed: false,
      );
    },
  );
  ref.onDispose(checkpointer.dispose);
  return checkpointer;
});
