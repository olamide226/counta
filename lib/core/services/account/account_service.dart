import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../domain/account/account.dart';

/// A one-time Apple or Google sign-in, ready to hand to Supabase.
class IdentityCredential {
  const IdentityCredential({
    required this.method,
    required this.idToken,
    this.accessToken,
    this.rawNonce,
  });

  final SignInMethod method;
  final String idToken;
  final String? accessToken;

  /// The nonce before hashing. Apple embeds the hash in its token; Supabase
  /// is given the raw value to check it against.
  final String? rawNonce;
}

/// Thrown by an [IdentitySource] when the person closed the Apple or Google
/// sheet. Not a failure.
class IdentityCancelled implements Exception {
  const IdentityCancelled();
}

/// Shows the Apple or Google sheet. Platform glue only.
abstract interface class IdentitySource {
  Future<IdentityCredential> credential(SignInMethod method);

  /// Forgets the Google account picked last time, so "sign in" after "sign
  /// out" asks again. Apple has no such state.
  Future<void> signOut();
}

/// Linking failed because the identity (or its email) already belongs to an
/// account: this is a returning user.
class IdentityAlreadyLinked implements Exception {
  const IdentityAlreadyLinked();
}

/// The parts of Supabase Auth an account needs. Narrow on purpose, so the
/// sign-in decisions below are testable without a server.
abstract interface class AuthGateway {
  /// Who the app is running as now.
  AccountStatus get status;

  /// Fires whenever [status] may have changed.
  Stream<AccountStatus> get changes;

  /// The current session's access token, refreshed first if it has expired.
  /// Null when there is no session at all.
  Future<String?> freshAccessToken();

  /// Attaches [credential] to the current (guest) account. Throws
  /// [IdentityAlreadyLinked] when it is someone's already.
  Future<void> link(IdentityCredential credential);

  /// Signs in as the account [credential] belongs to.
  Future<void> signIn(IdentityCredential credential);

  /// Ends this phone's session (only this phone's) and starts a new guest.
  Future<void> signOutToGuest();
}

/// Signing in, signing out and deleting the account.
///
/// The one rule everything here keeps: a person never loses minutes by
/// signing in. Either this phone's guest account gains the sign-in (and keeps
/// its minutes), or — when the identity already has an account — the app
/// switches to that account and carries this phone's guest minutes over.
class AccountService {
  AccountService({
    required this.auth,
    required this.identity,
    required this.backend,
    Future<void> Function(Duration) pause = _delay,
  }) : _pause = pause;

  final AuthGateway auth;
  final IdentitySource identity;

  /// Null in a build with no voice backend; there are no minutes to move then.
  final AccountBackend? backend;

  static const _moveAttempts = 3;
  final Future<void> Function(Duration) _pause;

  AccountStatus get status => auth.status;
  Stream<AccountStatus> get changes => auth.changes;

  /// Signs in with [method].
  Future<SignInResult> signIn(SignInMethod method) async {
    final IdentityCredential credential;
    try {
      credential = await identity.credential(method);
    } on IdentityCancelled {
      return const SignInCancelled();
    } catch (error) {
      debugPrint('Sign in with ${method.label} failed: $error');
      return const SignInFailed();
    }

    // Taken before anything changes: it is what proves, later, that this phone
    // held the guest whose minutes are being moved.
    final String? guestToken;
    try {
      guestToken = await auth.freshAccessToken();
    } catch (error) {
      debugPrint('No guest session to sign in from: $error');
      return const SignInFailed();
    }

    try {
      await auth.link(credential);
      return const SignInSucceeded(returning: false);
    } on IdentityAlreadyLinked {
      // Falls through to signing in as that account.
    } catch (error) {
      debugPrint('Linking ${method.label} failed: $error');
      return const SignInFailed();
    }

    // A returning user: this identity has an account already.
    try {
      await auth.signIn(credential);
    } catch (error) {
      debugPrint('Signing in with ${method.label} failed: $error');
      return const SignInFailed();
    }

    // Always asked, never decided here: the server knows the guest's balance
    // and answers "nothing to move" cheaply, while a stale balance on this
    // phone reading zero would strand the minutes for good.
    final backend = this.backend;
    if (backend == null || guestToken == null) {
      return const SignInSucceeded(returning: true);
    }
    for (var attempt = 1; attempt <= _moveAttempts; attempt++) {
      try {
        final moved = await backend.claimGuestMinutes(guestToken);
        return SignInSucceeded(returning: true, movedMinutes: moved);
      } on MergeRefused catch (refusal) {
        debugPrint('Moving guest minutes refused: $refusal');
        break;
      } catch (error) {
        debugPrint('Moving guest minutes failed (try $attempt): $error');
        if (attempt < _moveAttempts) await _pause(Duration(seconds: attempt));
      }
    }
    return const SignInSucceeded(returning: true, moveFailed: true);
  }

  /// Signs this phone out. The account and its minutes are untouched; the
  /// phone carries on as a new guest with none.
  Future<void> signOut() async {
    await _forgetIdentity();
    await auth.signOutToGuest();
  }

  /// Deletes the account and its minutes, then carries on as a new guest.
  /// Throws if the server could not delete it, leaving everything as it was.
  Future<void> deleteAccount() async {
    final backend = this.backend;
    if (backend == null) {
      throw StateError('No backend to delete the account on.');
    }
    await backend.deleteAccount();
    await signOut();
  }

  Future<void> _forgetIdentity() async {
    try {
      await identity.signOut();
    } catch (error) {
      // Only means the Google picker may preselect the same account next time.
      debugPrint('Identity sign-out failed: $error');
    }
  }
}

Future<void> _delay(Duration duration) => Future.delayed(duration);
