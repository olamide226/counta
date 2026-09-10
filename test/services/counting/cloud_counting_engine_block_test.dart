import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:counta/core/services/counting/cloud_counting_engine.dart';
import 'package:counta/domain/counting/block_service.dart';
import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/domain/counting/speech_socket.dart';

import '../../helpers/voice_fakes.dart';

/// 16 kHz mono PCM16: what the engine uses to place a connection's timeline on
/// the session's, and what the tests use to say "this much audio has flowed".
const int bytesPerSecond = 16000 * 2;

void main() {
  group('CloudCountingEngine block lifecycle', () {
    late List<FakeSpeechSocket> sockets;
    late FakeAudioSource audio;

    SpeechSocket makeSocket() {
      final socket = FakeSpeechSocket('s${sockets.length + 1}');
      sockets.add(socket);
      return socket;
    }

    CloudCountingEngine engineWith(
      FakeBlockService blocks, {
      Duration renewalOverlap = const Duration(seconds: 3),
      Duration renewalRetryDelay = const Duration(seconds: 10),
      Duration maxReconnectBackoff = const Duration(milliseconds: 20),
    }) => CloudCountingEngine(
      blockService: blocks,
      audioSource: audio,
      socketFactory: makeSocket,
      renewalOverlap: renewalOverlap,
      renewalRetryDelay: renewalRetryDelay,
      maxReconnectBackoff: maxReconnectBackoff,
      // Off in these tests: they drive time by hand and a periodic watchdog
      // would fire a reconnect in the middle of an elapse().
      transcriptionSilenceTimeout: const Duration(days: 1),
      transcriptionWatchdogInterval: const Duration(days: 1),
    );

    setUp(() {
      sockets = <FakeSpeechSocket>[];
      audio = FakeAudioSource();
    });

    group('acquiring the first block (3.1)', () {
      test('a block is granted before any socket is opened', () async {
        final blocks = FakeBlockService();
        final engine = engineWith(blocks);
        addTearDown(engine.dispose);

        await engine.start(testPhrase);
        await pumpEventQueue();

        expect(blocks.acquiredSessionIds, hasLength(1));
        expect(sockets.single.connectCount, 1);
        // The socket is opened with the token that came *with* the block, not
        // with anything the client held before it.
        expect(sockets.single.tokensSeen, ['token-1']);
        expect(engine.currentBlock?.id, 'block-1');
        expect(engine.blocksUsed, 1);
        expect(engine.currentStatus, EngineStatus.live);
      });

      test(
        'the session id is a uuid the server can key a renewal on',
        () async {
          final blocks = FakeBlockService();
          final engine = engineWith(blocks);
          addTearDown(engine.dispose);

          await engine.start(testPhrase);

          expect(engine.sessionId, isNotNull);
          expect(
            blocks.acquiredSessionIds.single,
            matches(
              RegExp(
                r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
                r'[0-9a-f]{12}$',
              ),
            ),
          );
          expect(blocks.acquiredSessionIds.single, engine.sessionId);
        },
      );

      test('a refused microphone buys nothing (2.2)', () async {
        // Capture is confirmed before the credential is fetched precisely so a
        // session that can never deliver audio never spends credit.
        audio.permissionGranted = false;
        final blocks = FakeBlockService();
        final engine = engineWith(blocks);
        addTearDown(engine.dispose);

        await engine.start(testPhrase);
        await pumpEventQueue();

        expect(engine.currentStatus, EngineStatus.permissionDenied);
        expect(blocks.acquiredSessionIds, isEmpty);
        expect(sockets, isEmpty);
      });

      test('402 at start reports exhausted and opens no socket', () async {
        final blocks = FakeBlockService(
          failures: const [BlockInsufficientCredit(balance: 2, required: 5)],
        );
        final engine = engineWith(blocks);
        addTearDown(engine.dispose);
        final diagnostics = <String>[];
        final sub = engine.diagnostics.listen(diagnostics.add);

        await expectLater(
          engine.start(testPhrase),
          throwsA(isA<BlockInsufficientCredit>()),
        );
        await pumpEventQueue();

        expect(engine.currentStatus, EngineStatus.exhausted);
        expect(sockets, isEmpty);
        // The microphone is handed straight back rather than held open behind
        // a paywall.
        expect(audio.stopCount, greaterThanOrEqualTo(1));
        expect(diagnostics.first, contains('2 left'));
        await sub.cancel();
      });

      for (final failure in <BlockFailure>[
        const BlockUnauthenticated(),
        const BlockInFlight(),
        const BlockRateLimited(),
        const BlockProviderUnavailable(),
        const BlockRequestRejected(status: 400, reason: 'invalid_session_id'),
        BlockUnreachable(Exception('offline')),
      ]) {
        test(
          '${failure.runtimeType} at start fails the session cleanly',
          () async {
            final blocks = FakeBlockService(failures: [failure]);
            final engine = engineWith(blocks);
            addTearDown(engine.dispose);
            final diagnostics = <String>[];
            final sub = engine.diagnostics.listen(diagnostics.add);

            await expectLater(engine.start(testPhrase), throwsA(failure));
            await pumpEventQueue();

            expect(engine.currentStatus, EngineStatus.error);
            expect(sockets, isEmpty, reason: 'no block, no connection');
            expect(audio.stopCount, greaterThanOrEqualTo(1));
            expect(diagnostics, contains(failure.message));
            await sub.cancel();
          },
        );
      }
    });

    group('terminal failures tear the whole session down', () {
      test('a start that cannot connect disarms the renewal timer', () {
        fakeAsync((async) {
          final blocks = FakeBlockService(blockSeconds: 10);
          final engine = CloudCountingEngine(
            blockService: blocks,
            audioSource: audio,
            socketFactory: () {
              final socket = _RefusingSocket('s${sockets.length + 1}');
              sockets.add(socket);
              return socket;
            },
            transcriptionSilenceTimeout: const Duration(days: 1),
            transcriptionWatchdogInterval: const Duration(days: 1),
          );

          engine.start(testPhrase).catchError((Object _) {});
          async.flushMicrotasks();

          expect(engine.currentStatus, EngineStatus.error);
          expect(audio.stopCount, greaterThanOrEqualTo(1));
          expect(blocks.releases.single.blockId, 'block-1');

          // The block bought for the failed start armed a renewal timer that
          // nothing cancelled: with no microphone and no socket, the engine
          // went on buying a block every nine seconds for the life of the app.
          async.elapse(const Duration(minutes: 10));
          async.flushMicrotasks();
          expect(blocks.acquiredSessionIds, hasLength(1));

          engine.dispose();
          async.flushTimers();
        });
      });

      test('giving up on a reconnect releases the block and the mic', () async {
        final blocks = FakeBlockService(blockSeconds: 300);
        final socket = _RefusableSocket('s1');
        final engine = CloudCountingEngine(
          blockService: blocks,
          audioSource: audio,
          socketFactory: () {
            sockets.add(socket);
            return socket;
          },
          reconnectWindow: const Duration(milliseconds: 100),
          maxReconnectBackoff: const Duration(milliseconds: 10),
          transcriptionSilenceTimeout: const Duration(days: 1),
          transcriptionWatchdogInterval: const Duration(days: 1),
        );
        addTearDown(engine.dispose);

        await engine.start(testPhrase);
        await pumpEventQueue();
        final stopsBefore = audio.stopCount;

        socket.failConnects = true;
        socket.emitDrop(reason: 'server hung up');
        await Future<void>.delayed(const Duration(milliseconds: 400));

        expect(engine.currentStatus, EngineStatus.error);
        // An errored session used to keep the microphone open and go on
        // buying blocks it had no socket for.
        expect(audio.stopCount, greaterThan(stopsBefore));
        expect(blocks.releases.single.blockId, 'block-1');
        expect(blocks.acquiredSessionIds, hasLength(1));
      });

      test('a reconnect with nothing to restore does not strand', () async {
        // A microphone stall during the block round trip schedules a
        // reconnect while the session still has no socket. The attempt used
        // to return early, leaving `reconnecting` with capture torn down, no
        // timer, and no way back to `live` or `error`.
        final blocks = _SlowAcquireService(const Duration(milliseconds: 500));
        final engine = CloudCountingEngine(
          blockService: blocks,
          audioSource: audio,
          socketFactory: makeSocket,
          reconnectWindow: const Duration(milliseconds: 60),
          maxReconnectBackoff: const Duration(milliseconds: 10),
          transcriptionSilenceTimeout: const Duration(days: 1),
          transcriptionWatchdogInterval: const Duration(days: 1),
        );
        addTearDown(engine.dispose);

        engine.start(testPhrase).catchError((Object _) {});
        await pumpEventQueue();
        audio.emitStall();

        await Future<void>.delayed(const Duration(milliseconds: 250));

        expect(engine.currentStatus, isNot(EngineStatus.reconnecting));
        expect(engine.currentStatus, EngineStatus.error);
      });
    });

    group('renewal at 90% (3.9)', () {
      test('the next block is requested at nine tenths of this one', () {
        fakeAsync((async) {
          final blocks = FakeBlockService(blockSeconds: 300);
          final engine = engineWith(blocks);

          engine.start(testPhrase);
          async.flushMicrotasks();
          expect(blocks.acquiredSessionIds, hasLength(1));

          async.elapse(const Duration(seconds: 269));
          async.flushMicrotasks();
          expect(
            blocks.acquiredSessionIds,
            hasLength(1),
            reason: 'renewal is at 270s, not before',
          );

          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();
          expect(blocks.acquiredSessionIds, hasLength(2));

          // Same session id: that is what tells the server this is a renewal
          // to grant and supersede, rather than a second concurrent session to
          // refuse with a 409.
          expect(blocks.acquiredSessionIds[1], blocks.acquiredSessionIds[0]);
          expect(engine.blocksUsed, 2);
          expect(engine.currentBlock?.id, 'block-2');

          engine.dispose();
          async.flushTimers();
        });
      });

      test('the new socket is open before the old one is closed', () {
        fakeAsync((async) {
          final blocks = FakeBlockService(blockSeconds: 300);
          final engine = engineWith(
            blocks,
            renewalOverlap: const Duration(seconds: 3),
          );

          engine.start(testPhrase);
          async.flushMicrotasks();

          async.elapse(const Duration(seconds: 270));
          async.flushMicrotasks();

          expect(sockets, hasLength(2));
          expect(sockets[1].connectCount, 1);
          expect(sockets[1].tokensSeen, ['token-2']);
          expect(
            sockets[0].closeCount,
            0,
            reason: 'the outgoing connection carries the seam',
          );

          // Both are fed while the seam lasts, so the incoming connection has
          // real speech through it before it is alone with the session.
          audio.emitFrame();
          async.flushMicrotasks();
          expect(sockets[0].sentFrames, isNotEmpty);
          expect(sockets[1].sentFrames, isNotEmpty);

          async.elapse(const Duration(seconds: 3));
          async.flushMicrotasks();

          expect(sockets[0].closeCount, 1);
          expect(sockets[0].disposed, isTrue);
          expect(engine.currentStatus, EngineStatus.live);

          engine.dispose();
          async.flushTimers();
        });
      });

      test('audio duplicated across the seam is counted once', () {
        fakeAsync((async) {
          // A short block keeps the byte arithmetic below readable: the
          // renewal lands at 9s, which is 288000 bytes of 16 kHz mono PCM16.
          final blocks = FakeBlockService(blockSeconds: 10);
          final engine = engineWith(
            blocks,
            renewalOverlap: const Duration(seconds: 2),
          );

          engine.start(testPhrase);
          async.flushMicrotasks();

          // The confirmation frame is 320 bytes; top the session up to exactly
          // nine seconds of streamed audio before the seam.
          audio.emitFrame(9 * bytesPerSecond - 320);
          async.flushMicrotasks();

          async.elapse(const Duration(seconds: 9));
          async.flushMicrotasks();
          expect(sockets, hasLength(2));

          // The first frame the incoming connection receives is what fixes its
          // place on the session timeline: nine seconds in.
          audio.emitFrame();
          async.flushMicrotasks();

          // One repetition, transcribed by both connections. Each numbers its
          // own timeline from zero, so the same audio is 9.2s to the outgoing
          // connection and 0.2s to the incoming one.
          sockets[0].emitSegment(
            finalSegment("I'm rich in wisdom", start: 9.2, duration: 1.0),
          );
          sockets[1].emitSegment(
            finalSegment("I'm rich in wisdom", start: 0.2, duration: 1.0),
          );
          async.flushMicrotasks();

          expect(
            engine.voiceCount,
            1,
            reason: 'the overlap window must not double count',
          );

          // Audio only the incoming connection heard still counts.
          sockets[1].emitSegment(
            finalSegment("I'm rich in wisdom", start: 2.0, duration: 1.0),
          );
          async.flushMicrotasks();
          expect(engine.voiceCount, 2);

          engine.dispose();
          async.flushTimers();
        });
      });

      test('a renewal that cannot connect keeps the block it paid for', () {
        fakeAsync((async) {
          final blocks = FakeBlockService(blockSeconds: 300);
          final engine = CloudCountingEngine(
            blockService: blocks,
            audioSource: audio,
            socketFactory: () {
              final socket = sockets.isEmpty
                  ? FakeSpeechSocket('s1')
                  : _RefusingSocket('s${sockets.length + 1}');
              sockets.add(socket);
              return socket;
            },
            renewalRetryDelay: const Duration(seconds: 5),
            transcriptionSilenceTimeout: const Duration(days: 1),
            transcriptionWatchdogInterval: const Duration(days: 1),
          );

          engine.start(testPhrase);
          async.flushMicrotasks();

          async.elapse(const Duration(seconds: 270));
          async.flushMicrotasks();
          expect(blocks.acquiredSessionIds, hasLength(1 + 1));

          // The retry reuses the block already bought instead of buying a
          // second one for the same stretch of time.
          async.elapse(const Duration(seconds: 5));
          async.flushMicrotasks();
          expect(
            blocks.acquiredSessionIds,
            hasLength(2),
            reason: 'the block is paid for; only the socket failed',
          );

          engine.dispose();
          async.flushTimers();
        });
      });
    });

    group('402 at renewal (3.10)', () {
      test('the current block runs out before the session does', () {
        fakeAsync((async) {
          final blocks = FakeBlockService(
            blockSeconds: 10,
            failures: const [
              null,
              BlockInsufficientCredit(balance: 1, required: 5),
            ],
          );
          final engine = engineWith(blocks);
          final statuses = <EngineStatus>[];
          engine.status.listen(statuses.add);

          engine.start(testPhrase);
          async.flushMicrotasks();

          sockets[0].emitSegment(
            finalSegment("I'm rich in wisdom", start: 1.0, duration: 1.0),
          );
          async.flushMicrotasks();
          expect(engine.voiceCount, 1);

          async.elapse(const Duration(seconds: 9));
          async.flushMicrotasks();

          // Refused, but the block already paid for is not cut short.
          expect(engine.currentStatus, EngineStatus.live);
          sockets[0].emitSegment(
            finalSegment("I'm rich in wisdom", start: 4.0, duration: 1.0),
          );
          async.flushMicrotasks();
          expect(engine.voiceCount, 2, reason: 'still counting until it ends');

          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();

          expect(engine.currentStatus, EngineStatus.exhausted);
          expect(statuses.last, EngineStatus.exhausted);
          // The count survives, capture stops, and the block is reported on.
          expect(engine.voiceCount, 2);
          expect(engine.totalCount, 2);
          expect(audio.stopCount, greaterThanOrEqualTo(1));
          expect(blocks.releases.single.blockId, 'block-1');
          expect(blocks.releases.single.detections, 2);

          engine.dispose();
          async.flushTimers();
        });
      });

      test('tapping still counts after exhaustion', () {
        fakeAsync((async) {
          final blocks = FakeBlockService(
            blockSeconds: 10,
            failures: const [
              null,
              BlockInsufficientCredit(balance: 0, required: 5),
            ],
          );
          final engine = engineWith(blocks);

          engine.start(testPhrase);
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 10));
          async.flushMicrotasks();
          expect(engine.currentStatus, EngineStatus.exhausted);

          engine.incrementManual();
          expect(engine.totalCount, 1);

          engine.dispose();
          async.flushTimers();
        });
      });

      test('a renewal that never succeeds pauses rather than exhausts', () {
        fakeAsync((async) {
          final blocks = FakeBlockService(
            blockSeconds: 10,
            failures: const [
              null,
              BlockProviderUnavailable(),
              BlockProviderUnavailable(),
            ],
          );
          final engine = engineWith(
            blocks,
            renewalRetryDelay: const Duration(seconds: 30),
          );

          engine.start(testPhrase);
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 10));
          async.flushMicrotasks();

          // Out of paid time but not out of credit: the user has minutes left,
          // so this is a pause to recover from, not a paywall.
          expect(engine.currentStatus, EngineStatus.degraded);

          engine.dispose();
          async.flushTimers();
        });
      });
    });

    group('reconnection inside a block (5.4)', () {
      test('a dropped socket resumes on the same block', () async {
        final blocks = FakeBlockService(blockSeconds: 300);
        final engine = engineWith(blocks);
        addTearDown(engine.dispose);

        await engine.start(testPhrase);
        await pumpEventQueue();
        expect(blocks.acquiredSessionIds, hasLength(1));

        sockets.single.emitDrop(reason: 'server hung up');
        await Future<void>.delayed(const Duration(milliseconds: 200));

        // Reconnecting must not buy anything. The server would not even refuse
        // it — a grant carrying the live block's session id reads as a renewal
        // — so every dropped socket would debit another block.
        expect(
          blocks.acquiredSessionIds,
          hasLength(1),
          reason: 'a reconnect reuses the block it is already inside',
        );
        expect(sockets.single.connectCount, 2);
        expect(sockets.single.tokensSeen, ['token-1', 'token-1']);
        expect(engine.currentStatus, EngineStatus.live);
        expect(engine.blocksUsed, 1);
      });

      test('counting continues after a reconnect', () async {
        final blocks = FakeBlockService(blockSeconds: 300);
        final engine = engineWith(blocks);
        addTearDown(engine.dispose);

        await engine.start(testPhrase);
        await pumpEventQueue();

        // Thirty-one seconds of audio have been streamed when the drop lands,
        // so the reconnected connection's timeline starts there.
        audio.emitFrame(31 * bytesPerSecond - 320);
        await pumpEventQueue();
        sockets.single.emitSegment(
          finalSegment("I'm rich in wisdom", start: 30.0, duration: 1.0),
        );
        await pumpEventQueue();
        expect(engine.voiceCount, 1);

        sockets.single.emitDrop(reason: 'blip');
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(engine.currentStatus, EngineStatus.live);

        // The reconnected socket restarts the provider's clock at zero. Before
        // the per-connection rebase this segment looked older than the last
        // accepted match and was silently dropped, for the rest of the session.
        audio.emitFrame();
        await pumpEventQueue();
        sockets.single.emitSegment(
          finalSegment("I'm rich in wisdom", start: 0.5, duration: 1.0),
        );
        await pumpEventQueue();

        expect(engine.voiceCount, 2);
      });
    });

    group('release on stop (3.5, 3.11)', () {
      test('an empty session asserts the refund it is owed', () async {
        final blocks = FakeBlockService(blockSeconds: 300);
        final engine = engineWith(blocks);

        await engine.start(testPhrase);
        await pumpEventQueue();
        await engine.stop();

        final release = blocks.releases.single;
        expect(release.blockId, 'block-1');
        expect(release.detections, 0);
        expect(release.streamedSecs, lessThan(30));
        // Asserted, not decided: the server validates it against its own
        // record of when the block was granted.
        expect(release.eligibleForRefund, isTrue);

        await engine.dispose();
      });

      test('a session that counted reports its detections honestly', () async {
        final blocks = FakeBlockService(blockSeconds: 300);
        final engine = engineWith(blocks);

        await engine.start(testPhrase);
        await pumpEventQueue();
        sockets.single.emitSegment(
          finalSegment("I'm rich in wisdom", start: 1.0, duration: 1.0),
        );
        sockets.single.emitSegment(
          finalSegment("I'm rich in wisdom", start: 4.0, duration: 1.0),
        );
        await pumpEventQueue();

        await engine.stop();

        final release = blocks.releases.single;
        expect(release.detections, 2);
        expect(
          release.eligibleForRefund,
          isFalse,
          reason: 'a block that delivered detections was not wasted',
        );

        await engine.dispose();
      });

      test('only the live block is released; renewals supersede', () {
        fakeAsync((async) {
          final blocks = FakeBlockService(blockSeconds: 10);
          final engine = engineWith(
            blocks,
            renewalOverlap: const Duration(seconds: 1),
          );

          engine.start(testPhrase);
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 9));
          async.flushMicrotasks();
          expect(engine.currentBlock?.id, 'block-2');

          engine.stop();
          async.flushMicrotasks();

          // The server marks the block a renewal replaces as superseded in the
          // grant that replaced it, so releasing it again would be noise.
          expect(blocks.releases, hasLength(1));
          expect(blocks.releases.single.blockId, 'block-2');

          engine.dispose();
          async.flushTimers();
        });
      });

      test(
        'a release failure never breaks the stop the user asked for',
        () async {
          final blocks = _FailingReleaseService();
          final engine = CloudCountingEngine(
            blockService: blocks,
            audioSource: audio,
            socketFactory: makeSocket,
          );

          await engine.start(testPhrase);
          await pumpEventQueue();
          final summary = await engine.stop();

          expect(summary.totalCount, 0);
          expect(engine.currentStatus, EngineStatus.idle);

          await engine.dispose();
        },
      );
    });
  });
}

/// A socket that refuses to connect, standing in for a renewal whose new
/// connection cannot be established.
class _RefusingSocket extends FakeSpeechSocket {
  _RefusingSocket(super.name);

  @override
  Future<void> connect({
    required String apiKeyOrToken,
    PhraseSpec? phrase,
  }) async {
    throw StateError('cannot connect');
  }
}

/// A socket that can be told to refuse the *next* connect, standing in for a
/// server that hangs up and then will not have the session back.
class _RefusableSocket extends FakeSpeechSocket {
  _RefusableSocket(super.name);

  bool failConnects = false;

  @override
  Future<void> connect({
    required String apiKeyOrToken,
    PhraseSpec? phrase,
  }) async {
    if (failConnects) throw StateError('cannot reconnect');
    return super.connect(apiKeyOrToken: apiKeyOrToken, phrase: phrase);
  }
}

/// Grants after a delay, so a test can act during the round trip the way a
/// real device does on a slow network.
class _SlowAcquireService extends FakeBlockService {
  _SlowAcquireService(this.delay);

  final Duration delay;

  @override
  Future<VoiceBlock> acquire(String sessionId) async {
    await Future<void>.delayed(delay);
    return super.acquire(sessionId);
  }
}

/// A block service whose release always fails, the way an offline device's
/// would when the user ends a session in a tunnel.
class _FailingReleaseService extends FakeBlockService {
  @override
  Future<BlockRelease> release(
    String blockId, {
    required int streamedSecs,
    required int detections,
    required bool eligibleForRefund,
  }) async {
    throw const BlockProviderUnavailable();
  }
}
