import 'package:counta/data/repositories/session_checkpoint_repository.dart';
import 'package:counta/domain/models/count_session.dart';

/// In-memory [SessionCheckpointStore] shared by every checkpoint test.
///
/// Counts calls as well as holding the value, so tests can assert on write
/// *pressure* — writing rarely is the checkpointer's whole job — and not only
/// on the final contents.
class InMemoryCheckpointStore implements SessionCheckpointStore {
  CountSession? current;
  int writes = 0;
  int clears = 0;
  int takes = 0;

  @override
  CountSession? read() => current;

  @override
  Future<void> write(CountSession checkpoint) async {
    current = checkpoint;
    writes++;
  }

  @override
  Future<void> clear() async {
    current = null;
    clears++;
  }

  @override
  Future<CountSession?> take() async {
    takes++;
    final checkpoint = current;
    current = null;
    return checkpoint;
  }
}
