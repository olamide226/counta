import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../domain/account/account.dart';
import 'account_service.dart';

/// [AuthGateway] on Supabase Auth.
class SupabaseAuthGateway implements AuthGateway {
  SupabaseAuthGateway(
    this._auth, {
    required Future<String?> Function() accessToken,
  }) : _accessToken = accessToken;

  final GoTrueClient _auth;

  /// The app's one session resolver (`resolveAccessToken`), shared with the
  /// voice backend client so both agree on which session is current.
  final Future<String?> Function() _accessToken;

  @override
  AccountStatus get status => statusOf(_auth.currentUser);

  @override
  Stream<AccountStatus> get changes =>
      _auth.onAuthStateChange.map((event) => statusOf(event.session?.user));

  @override
  Future<String?> freshAccessToken() => _accessToken();

  @override
  Future<void> link(IdentityCredential credential) async {
    try {
      await _auth.linkIdentityWithIdToken(
        provider: _providerOf(credential.method),
        idToken: credential.idToken,
        accessToken: credential.accessToken,
        nonce: credential.rawNonce,
      );
    } on AuthException catch (error) {
      if (isAlreadyLinked(error)) throw const IdentityAlreadyLinked();
      rethrow;
    }
  }

  @override
  Future<void> signIn(IdentityCredential credential) async {
    await _auth.signInWithIdToken(
      provider: _providerOf(credential.method),
      idToken: credential.idToken,
      accessToken: credential.accessToken,
      nonce: credential.rawNonce,
    );
  }

  @override
  Future<void> signOutToGuest() async {
    try {
      // This phone only: signing out here must not sign out the user's other
      // phones.
      await _auth.signOut(scope: SignOutScope.local);
    } catch (error) {
      // A deleted account's session cannot be ended on the server; it is
      // cleared locally regardless.
      debugPrint('Sign-out reported: $error');
    }
    await _auth.signInAnonymously();
  }

  static OAuthProvider _providerOf(SignInMethod method) => switch (method) {
    SignInMethod.apple => OAuthProvider.apple,
    SignInMethod.google => OAuthProvider.google,
  };

  /// Whether linking failed because the identity is someone's already.
  ///
  /// That includes an account that holds the same email under another
  /// provider: signing in with Apple and later with Google on the same address
  /// is one person, and the sign-in that follows lands on that account.
  @visibleForTesting
  static bool isAlreadyLinked(AuthException error) =>
      error.code == ErrorCode.identityAlreadyExists.code ||
      error.code == ErrorCode.emailExists.code;

  /// What the app shows for [user].
  @visibleForTesting
  static AccountStatus statusOf(User? user) {
    if (user == null || user.isAnonymous) return const GuestAccount();
    final provider = user.appMetadata['provider'];
    final providers = user.appMetadata['providers'];
    bool uses(String name) =>
        provider == name || (providers is List && providers.contains(name));
    return SignedInAccount(
      method: uses('apple')
          ? SignInMethod.apple
          : uses('google')
          ? SignInMethod.google
          : null,
      email: (user.email?.isEmpty ?? true) ? null : user.email,
    );
  }
}
