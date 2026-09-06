import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/session_checkpoint_repository.dart';
import '../../domain/models/count_session.dart';
import 'counter_provider.dart';
import 'hive_providers.dart';
import 'session_checkpointer.dart';
import 'sessions_provider.dart';

/// The checkpoint worth offering back to the user after an unexpected
/// termination, or null when there is nothing to recover.
///
/// A checkpoint at zero is not worth a prompt: nothing was lost.
CountSession? pendingRecovery(SessionCheckpointStore store) {
  final checkpoint = store.read();
  if (checkpoint == null || checkpoint.finalCount <= 0) return null;
  return checkpoint;
}

/// Handles what the user decides to do with a recovered checkpoint
/// (requirement 7.2).
class SessionRecovery {
  final Ref _ref;

  SessionRecovery(this._ref);

  CountSession? get pending =>
      pendingRecovery(_ref.read(sessionCheckpointRepositoryProvider));

  /// Persists the checkpoint to history as a recovered session and clears it.
  Future<void> save(CountSession checkpoint) async {
    await _ref
        .read(sessionsProvider.notifier)
        .saveSession(checkpoint.copyWith(completed: false));
    await _ref.read(sessionCheckpointerProvider).clear();
  }

  /// Drops the checkpoint without keeping a record.
  Future<void> discard() async {
    await _ref.read(sessionCheckpointerProvider).clear();
  }

  /// Loads the checkpointed count back into the live counter so the user can
  /// carry on where the crash left them. The checkpointer takes over from
  /// here, so the old checkpoint is cleared rather than left to go stale.
  Future<void> resume(CountSession checkpoint) async {
    await _ref.read(sessionCheckpointerProvider).clear();
    _ref.read(counterProvider.notifier).loadSession(checkpoint);
  }
}

final sessionRecoveryProvider = Provider<SessionRecovery>(SessionRecovery.new);
