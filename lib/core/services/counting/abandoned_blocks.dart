import 'package:flutter/foundation.dart';

import '../../../domain/counting/block_service.dart';
import '../../../domain/counting/open_block_store.dart';

/// Hands back every block a previous run was killed holding, with the last
/// moment that run was known to be streaming, so the server returns the part
/// that was never used. Answers how many were settled.
///
/// Run at launch, before anything can start a session: the list is read
/// once, up front, so a block the new run goes on to buy is never in it.
/// A release that fails stays noted for the next launch; one the server no
/// longer knows is dropped.
Future<int> settleAbandonedBlocks(
  OpenBlockStore store,
  BlockService service,
) async {
  final held = store.all();
  var settled = 0;
  for (final MapEntry(key: blockId, value: aliveAt) in held.entries) {
    try {
      await service.release(
        blockId,
        // Unknown: the run that knew them is gone. Only `endedAt` is used to
        // charge, and the server never gives a claimed end a free refund.
        streamedSecs: 0,
        detections: 0,
        eligibleForRefund: false,
        endedAt: aliveAt,
      );
      await store.forget(blockId);
      settled++;
    } on BlockNotFound {
      await store.forget(blockId);
    } on BlockFailure catch (failure) {
      debugPrint('Abandoned block $blockId not settled yet: $failure');
    }
  }
  return settled;
}
