import 'dart:async';

import 'package:counta/core/services/account/account_service.dart';
import 'package:counta/core/services/account/supabase_auth_gateway.dart';
import 'package:counta/domain/account/account.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeIdentity implements IdentitySource {
  Object? throwOnCredential;
  int signOuts = 0;

  @override
  Future<IdentityCredential> credential(SignInMethod method) async {
    final error = throwOnCredential;
    if (error != null) throw error;
    return IdentityCredential(method: method, idToken: 'id-token');
  }

  @override
  Future<void> signOut() async => signOuts++;
}

class _FakeAuth implements AuthGateway {
  String? token = 'guest-token';
  LinkRefused? refuseLink;
  Object? failSignIn;
  final calls = <String>[];

  @override
  AccountStatus status = const GuestAccount();

  @override
  Stream<AccountStatus> get changes => const Stream.empty();

  @override
  Future<String?> freshAccessToken() async => token;

  @override
  Future<void> link(IdentityCredential credential) async {
    calls.add('link');
    final refusal = refuseLink;
    if (refusal != null) throw refusal;
  }

  @override
  Future<void> signIn(IdentityCredential credential) async {
    calls.add('signIn');
    final error = failSignIn;
    if (error != null) throw error;
  }

  @override
  Future<void> signOutToGuest() async => calls.add('signOutToGuest');
}

class _FakeBackend implements AccountBackend {
  int moves = 0;
  int failMoves = 0;
  final guestTokens = <String>[];
  bool deleted = false;
  Object? failDelete;

  @override
  Future<int> claimGuestMinutes(String guestAccessToken) async {
    guestTokens.add(guestAccessToken);
    if (failMoves > 0) {
      failMoves--;
      throw Exception('offline');
    }
    moves++;
    return 42;
  }

  @override
  Future<void> deleteAccount() async {
    final error = failDelete;
    if (error != null) throw error;
    deleted = true;
  }
}

void main() {
  late _FakeIdentity identity;
  late _FakeAuth auth;
  late _FakeBackend backend;
  late AccountService service;

  setUp(() {
    identity = _FakeIdentity();
    auth = _FakeAuth();
    backend = _FakeBackend();
    service = AccountService(
      auth: auth,
      identity: identity,
      backend: backend,
      pause: (_) async {},
    );
  });

  group('signIn', () {
    test('a first sign-in links to the guest and moves nothing', () async {
      final result = await service.signIn(SignInMethod.apple);

      expect(result, isA<SignInSucceeded>());
      expect((result as SignInSucceeded).returning, isFalse);
      expect(auth.calls, ['link']);
      expect(backend.guestTokens, isEmpty);
    });

    test('closing the sheet is a cancel, and nothing is touched', () async {
      identity.throwOnCredential = const IdentityCancelled();

      expect(await service.signIn(SignInMethod.google), isA<SignInCancelled>());
      expect(auth.calls, isEmpty);
    });

    test('a sheet that fails is a failure', () async {
      identity.throwOnCredential = Exception('no network');

      expect(await service.signIn(SignInMethod.apple), isA<SignInFailed>());
      expect(auth.calls, isEmpty);
    });

    test(
      'an identity with an account already switches to it and moves the '
      "guest's minutes using the guest token taken before the switch",
      () async {
        auth.refuseLink = const LinkRefused(LinkRefusal.alreadyLinked);

        final result = await service.signIn(SignInMethod.apple);

        expect(auth.calls, ['link', 'signIn']);
        expect(backend.guestTokens, ['guest-token']);
        expect(result, isA<SignInSucceeded>());
        final succeeded = result as SignInSucceeded;
        expect(succeeded.returning, isTrue);
        expect(succeeded.movedMinutes, 42);
        expect(succeeded.moveFailed, isFalse);
      },
    );

    test('a guest known to hold no minutes skips the move', () async {
      auth.refuseLink = const LinkRefused(LinkRefusal.alreadyLinked);

      final result = await service.signIn(
        SignInMethod.apple,
        guestHasMinutes: false,
      );

      expect((result as SignInSucceeded).returning, isTrue);
      expect(backend.guestTokens, isEmpty);
    });

    test('a move that fails once is retried', () async {
      auth.refuseLink = const LinkRefused(LinkRefusal.alreadyLinked);
      backend.failMoves = 1;

      final result = await service.signIn(SignInMethod.google);

      expect((result as SignInSucceeded).movedMinutes, 42);
      expect(backend.guestTokens, hasLength(2));
    });

    test('a move that keeps failing still signs in, and says so', () async {
      auth.refuseLink = const LinkRefused(LinkRefusal.alreadyLinked);
      backend.failMoves = 99;

      final result = await service.signIn(SignInMethod.google);

      expect(result, isA<SignInSucceeded>());
      expect((result as SignInSucceeded).moveFailed, isTrue);
      expect(backend.guestTokens, hasLength(3));
    });

    test('any other link refusal fails without switching accounts', () async {
      auth.refuseLink = const LinkRefused(LinkRefusal.other);

      expect(await service.signIn(SignInMethod.apple), isA<SignInFailed>());
      expect(auth.calls, ['link']);
    });

    test('a switch that fails moves nothing', () async {
      auth.refuseLink = const LinkRefused(LinkRefusal.alreadyLinked);
      auth.failSignIn = Exception('refused');

      expect(await service.signIn(SignInMethod.apple), isA<SignInFailed>());
      expect(backend.guestTokens, isEmpty);
    });
  });

  test('sign out forgets the identity and becomes a new guest', () async {
    await service.signOut();

    expect(identity.signOuts, 1);
    expect(auth.calls, ['signOutToGuest']);
  });

  group('deleteAccount', () {
    test('deletes on the server, then becomes a new guest', () async {
      await service.deleteAccount();

      expect(backend.deleted, isTrue);
      expect(auth.calls, ['signOutToGuest']);
    });

    test('a server failure changes nothing on the phone', () async {
      backend.failDelete = Exception('offline');

      await expectLater(service.deleteAccount(), throwsException);
      expect(auth.calls, isEmpty);
    });
  });

  group('SupabaseAuthGateway', () {
    test('recognises an identity that belongs to another account', () {
      expect(
        SupabaseAuthGateway.isAlreadyLinked(
          const AuthException(
            'Identity is already linked to another user',
            code: 'identity_already_exists',
          ),
        ),
        isTrue,
      );
      expect(
        SupabaseAuthGateway.isAlreadyLinked(
          const AuthException('Invalid id token', code: 'bad_jwt'),
        ),
        isFalse,
      );
    });

    test('an anonymous or missing user is a guest', () {
      expect(SupabaseAuthGateway.statusOf(null), isA<GuestAccount>());
    });
  });
}
