import 'package:counta/core/services/counting/abandoned_blocks.dart';
import 'package:counta/domain/counting/block_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/open_block_store.dart';
import '../../helpers/voice_fakes.dart';

void main() {
  final killedAt = DateTime.utc(2026, 10, 28, 11, 43, 20);

  test(
    'a block a killed run held is handed back with when it stopped',
    () async {
      final store = InMemoryOpenBlockStore()..held['block-1'] = killedAt;
      final service = FakeBlockService();

      final settled = await settleAbandonedBlocks(store, service);

      expect(settled, 1);
      final release = service.releases.single;
      expect(release.blockId, 'block-1');
      expect(release.endedAt, killedAt);
      // Never asks for the free refund: a claimed end is charged at least a
      // minute, and the client does not pretend otherwise.
      expect(release.eligibleForRefund, isFalse);
      expect(store.held, isEmpty);
    },
  );

  test('one the server no longer knows is dropped', () async {
    final store = InMemoryOpenBlockStore()..held['gone'] = killedAt;

    await settleAbandonedBlocks(
      store,
      _AnsweringService(const BlockNotFound()),
    );

    expect(store.held, isEmpty);
  });

  test('one that cannot be handed back now is kept for next time', () async {
    final store = InMemoryOpenBlockStore()..held['block-1'] = killedAt;

    final settled = await settleAbandonedBlocks(
      store,
      _AnsweringService(BlockUnreachable(Exception('offline'))),
    );

    expect(settled, 0);
    expect(store.held.keys, ['block-1']);
  });

  test('nothing held, nothing sent', () async {
    final service = FakeBlockService();
    expect(await settleAbandonedBlocks(InMemoryOpenBlockStore(), service), 0);
    expect(service.releases, isEmpty);
  });
}

/// Answers every release with [failure].
class _AnsweringService extends FakeBlockService {
  _AnsweringService(this.failure);

  final BlockFailure failure;

  @override
  Future<BlockRelease> release(
    String blockId, {
    required int streamedSecs,
    required int detections,
    required bool eligibleForRefund,
    DateTime? endedAt,
  }) async {
    throw failure;
  }
}
