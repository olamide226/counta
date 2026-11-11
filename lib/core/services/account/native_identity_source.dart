import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../../domain/account/account.dart';
import 'account_service.dart';

/// The native Apple and Google sign-in sheets.
class NativeIdentitySource implements IdentitySource {
  NativeIdentitySource({
    required this.googleWebClientId,
    this.googleIosClientId,
  });

  final String googleWebClientId;
  final String? googleIosClientId;

  Future<void>? _googleReady;

  @override
  Future<IdentityCredential> credential(SignInMethod method) =>
      switch (method) {
        SignInMethod.apple => _apple(),
        SignInMethod.google => _google(),
      };

  Future<IdentityCredential> _apple() async {
    // Apple puts the nonce's hash in its token and Supabase checks it against
    // the raw value, which is what stops a captured token being replayed.
    final rawNonce = _nonce();
    final AuthorizationCredentialAppleID credential;
    try {
      credential = await SignInWithApple.getAppleIDCredential(
        // Email only. The name is not used anywhere, so it is not asked for.
        scopes: const [AppleIDAuthorizationScopes.email],
        nonce: sha256.convert(utf8.encode(rawNonce)).toString(),
      );
    } on SignInWithAppleAuthorizationException catch (error) {
      if (error.code == AuthorizationErrorCode.canceled) {
        throw const IdentityCancelled();
      }
      rethrow;
    }
    final idToken = credential.identityToken;
    if (idToken == null) throw StateError('Apple returned no ID token.');
    return IdentityCredential(
      method: SignInMethod.apple,
      idToken: idToken,
      rawNonce: rawNonce,
    );
  }

  Future<IdentityCredential> _google() async {
    await (_googleReady ??= GoogleSignIn.instance.initialize(
      clientId: googleIosClientId,
      serverClientId: googleWebClientId,
    ));
    final GoogleSignInAccount account;
    try {
      account = await GoogleSignIn.instance.authenticate();
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        throw const IdentityCancelled();
      }
      rethrow;
    }
    final idToken = account.authentication.idToken;
    if (idToken == null) throw StateError('Google returned no ID token.');
    return IdentityCredential(method: SignInMethod.google, idToken: idToken);
  }

  @override
  Future<void> signOut() async {
    if (_googleReady == null) return;
    await GoogleSignIn.instance.signOut();
  }

  static String _nonce([int length = 32]) {
    const chars =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
  }
}
