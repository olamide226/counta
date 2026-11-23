import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../domain/account/account.dart';
import 'account_service.dart';

/// [AuthGateway] on Supabase Auth.
class SupabaseAuthGateway implements AuthGateway {
  SupabaseAuthGateway(
    this._auth, {
    required Future<String?> Function() accessToken,
    RememberedSignIn? remembered,
    List<SignInMethod> offered = SignInMethod.values,
  }) : _accessToken = accessToken,
       _remembered = remembered ?? RememberedSignIn.inMemory(),
       _offered = offered;

  final GoTrueClient _auth;

  /// Which button this phone signed in with. The account itself can't say:
  /// one email signed in through Apple on one phone and Google on another is
  /// one account holding both identities.
  final RememberedSignIn _remembered;

  /// The methods this build offers, which narrows an account holding both to
  /// the one this phone could have used.
  final List<SignInMethod> _offered;

  /// The app's one session resolver (`resolveAccessToken`), shared with the
  /// voice backend client so both agree on which session is current.
  final Future<String?> Function() _accessToken;

  @override
  AccountStatus get status => _statusOf(_auth.currentUser);

  @override
  Stream<AccountStatus> get changes =>
      _auth.onAuthStateChange.map((event) => _statusOf(event.session?.user));

  AccountStatus _statusOf(User? user) =>
      statusOf(user, remembered: _remembered.read(), offered: _offered);

  /// Records [method] before the call that signs in with it, so the auth
  /// event that call raises already reads the new method, and puts the old
  /// one back if the call fails.
  Future<void> _withMethod(
    SignInMethod method,
    Future<void> Function() call,
  ) async {
    final previous = _remembered.read();
    await _remembered.write(method);
    try {
      await call();
    } catch (_) {
      await _remembered.write(previous);
      rethrow;
    }
  }

  @override
  Future<String?> freshAccessToken() => _accessToken();

  @override
  Future<void> link(IdentityCredential credential) async {
    try {
      await _withMethod(
        credential.method,
        () => _auth.linkIdentityWithIdToken(
          provider: _providerOf(credential.method),
          idToken: credential.idToken,
          accessToken: credential.accessToken,
          nonce: credential.rawNonce,
        ),
      );
    } on AuthException catch (error) {
      if (isAlreadyLinked(error)) throw const IdentityAlreadyLinked();
      rethrow;
    }
  }

  @override
  Future<void> signIn(IdentityCredential credential) => _withMethod(
    credential.method,
    () => _auth.signInWithIdToken(
      provider: _providerOf(credential.method),
      idToken: credential.idToken,
      accessToken: credential.accessToken,
      nonce: credential.rawNonce,
    ),
  );

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
    await _remembered.write(null);
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

  /// What the app shows for [user]: the method this phone [remembered]
  /// signing in with, when the account still holds it. Without one (a phone
  /// that signed in before this was remembered), the account's own methods
  /// narrowed to those [offered] here, and if that still leaves both, the one
  /// most recently used on any phone.
  @visibleForTesting
  static AccountStatus statusOf(
    User? user, {
    SignInMethod? remembered,
    Iterable<SignInMethod> offered = SignInMethod.values,
  }) {
    if (user == null || user.isAnonymous) return const GuestAccount();
    return SignedInAccount(
      method: _methodOf(user, remembered, offered),
      email: (user.email?.isEmpty ?? true) ? null : user.email,
    );
  }

  static SignInMethod? _methodOf(
    User user,
    SignInMethod? remembered,
    Iterable<SignInMethod> offered,
  ) {
    // When each of the account's methods was last used, by any phone.
    final lastUsed = <SignInMethod, String>{};
    for (final identity in user.identities ?? const <UserIdentity>[]) {
      final method = _methodNamed(identity.provider);
      if (method == null) continue;
      lastUsed[method] =
          identity.updatedAt ??
          identity.lastSignInAt ??
          identity.createdAt ??
          '';
    }
    if (lastUsed.isEmpty) {
      // A user object without identities: fall back to the metadata names.
      final provider = user.appMetadata['provider'];
      final providers = user.appMetadata['providers'];
      for (final name in [provider, if (providers is List) ...providers]) {
        final method = _methodNamed(name);
        if (method != null) lastUsed.putIfAbsent(method, () => '');
      }
    }
    if (lastUsed.isEmpty) return null;

    if (remembered != null && lastUsed.containsKey(remembered)) {
      return remembered;
    }
    final here = lastUsed.keys.where(offered.contains).toList();
    final candidates = here.isEmpty ? lastUsed.keys.toList() : here;
    if (candidates.length == 1) return candidates.single;
    // ISO-8601 timestamps from the same server compare as strings.
    candidates.sort((a, b) => lastUsed[b]!.compareTo(lastUsed[a]!));
    return candidates.first;
  }

  static SignInMethod? _methodNamed(Object? name) => switch (name) {
    'apple' => SignInMethod.apple,
    'google' => SignInMethod.google,
    _ => null,
  };
}

/// Which method this phone signed in with, kept on the phone alone.
class RememberedSignIn {
  RememberedSignIn({
    required SignInMethod? Function() read,
    required Future<void> Function(SignInMethod? method) write,
  }) : _read = read,
       _write = write;

  /// For tests and builds with no storage: remembered until the app closes.
  factory RememberedSignIn.inMemory() {
    SignInMethod? method;
    return RememberedSignIn(
      read: () => method,
      write: (value) async => method = value,
    );
  }

  final SignInMethod? Function() _read;
  final Future<void> Function(SignInMethod? method) _write;

  SignInMethod? read() => _read();
  Future<void> write(SignInMethod? method) => _write(method);
}
