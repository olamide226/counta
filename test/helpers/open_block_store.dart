import 'package:counta/domain/counting/open_block_store.dart';

/// [OpenBlockStore] in memory.
class InMemoryOpenBlockStore implements OpenBlockStore {
  final Map<String, DateTime> held = {};

  @override
  Future<void> remember(String blockId, DateTime aliveAt) async =>
      held[blockId] = aliveAt;

  @override
  Future<void> forget(String blockId) async => held.remove(blockId);

  @override
  Map<String, DateTime> all() => Map.of(held);
}
