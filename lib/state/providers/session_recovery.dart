import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/count_session.dart';
import 'counter_provider.dart';
import 'hive_providers.dart';
import 'session_checkpointer.dart';
import 'sessions_provider.dart';

/// The one startup step that has to happen before anything can count.
///
/// Takes the checkpoint left behind by a previous run — read *and* delete, in
/// one step — and only then attaches the checkpointer. Reading it without
/// removing it, or attaching the checkpointer first, let the first count of
/// this launch overwrite the record the user was about to be offered: the
/// store keys every write to the same slot.
///
/// Resolves to the checkpoint worth prompting about, or null when there is
/// nothing to recover. A checkpoint at zero is not worth a prompt: nothing was
/// lost.
final sessionStartupProvider = FutureProvider<CountSession?>((ref) async {
  final checkpoint = await ref
      .watch(sessionCheckpointRepositoryProvider)
      .take();

  // Deliberately after the take(): from here on the live session owns the
  // checkpoint slot.
  ref.watch(sessionCheckpointerProvider);

  if (checkpoint == null || checkpoint.finalCount <= 0) return null;
  return checkpoint;
});

/// Handles what the user decides to do with a recovered checkpoint
/// (requirement 7.2).
///
/// The checkpoint is already out of the store by the time any of these run —
/// [sessionStartupProvider] took it — so none of them has to clear it.
class SessionRecovery {
  final Ref _ref;

  SessionRecovery(this._ref);

  /// Persists the checkpoint to history as a recovered session.
  ///
  /// The record already carries `completed: false` from the checkpoint
  /// snapshot, so there is nothing to override here.
  Future<void> save(CountSession checkpoint) {
    return _ref.read(sessionsProvider.notifier).saveSession(checkpoint);
  }

  /// Loads the checkpointed session back into the live counter so the user can
  /// carry on where the crash left them, counts, phrase and start time intact.
  /// The checkpointer tracks it afresh from here under a new identity.
  void resume(CountSession checkpoint) {
    _ref.read(counterProvider.notifier).loadSession(checkpoint);
  }
}

final sessionRecoveryProvider = Provider<SessionRecovery>(SessionRecovery.new);
