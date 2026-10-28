import 'package:hive/hive.dart';

import '../hive/hive_init.dart';
import '../../domain/counting/open_block_store.dart';

/// [OpenBlockStore] in an untyped Hive box: block id to an ISO timestamp.
class HiveOpenBlockStore implements OpenBlockStore {
  HiveOpenBlockStore(this._box);

  final Box _box;

  @override
  Future<void> remember(String blockId, DateTime aliveAt) =>
      _box.put(blockId, aliveAt.toUtc().toIso8601String());

  @override
  Future<void> forget(String blockId) => _box.delete(blockId);

  @override
  Map<String, DateTime> all() => {
    for (final entry in _box.toMap().entries)
      if (entry.key is String && entry.value is String)
        if (DateTime.tryParse(entry.value as String) case final at?)
          entry.key as String: at,
  };
}

OpenBlockStore createOpenBlockStore() => HiveOpenBlockStore(getOpenBlocksBox());
