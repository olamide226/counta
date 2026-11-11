/// Who the app is running as, and what signing in did.
///
/// Every device starts as a guest: an anonymous account that already holds
/// voice minutes. Signing in only attaches an Apple or Google identity to that
/// account (or, on a phone that is new to an existing account, switches to
/// it), so nothing a guest bought is ever behind a sign-in wall.
library;

enum SignInMethod {
  apple('Apple'),
  google('Google');

  const SignInMethod(this.label);

  /// "Continue with Apple", "Signed in with Google".
  final String label;
}

sealed class AccountStatus {
  const AccountStatus();
}

/// Anonymous: minutes live on this phone only.
class GuestAccount extends AccountStatus {
  const GuestAccount();
}

/// Minutes are saved to an Apple or Google identity.
class SignedInAccount extends AccountStatus {
  const SignedInAccount({this.method, this.email});

  /// Null for an identity this build cannot name.
  final SignInMethod? method;

  /// Null, or an Apple relay address, when the user chose to hide it.
  final String? email;
}

sealed class SignInResult {
  const SignInResult();
}

class SignInSucceeded extends SignInResult {
  const SignInSucceeded({
    required this.returning,
    this.movedMinutes = 0,
    this.moveFailed = false,
  });

  /// True when the identity already had an account and the app switched to
  /// it — the "restore on a new phone" case. False when this phone's account
  /// simply gained a sign-in.
  final bool returning;

  /// Minutes this phone held as a guest that were moved into the account.
  final int movedMinutes;

  /// The account is signed in, but this phone's guest minutes could not be
  /// moved across. Rare; worth saying, never worth blocking on.
  final bool moveFailed;
}

/// The user closed the Apple or Google sheet. Not an error; say nothing.
class SignInCancelled extends SignInResult {
  const SignInCancelled();
}

class SignInFailed extends SignInResult {
  const SignInFailed([
    this.message = "Couldn't sign in. Check your connection and try again.",
  ]);

  final String message;
}

/// The two backend calls an account needs beyond Supabase Auth itself.
///
/// Implemented by the voice backend client, which is the one thing that talks
/// to the voice-block function.
abstract interface class AccountBackend {
  /// Moves a guest's minutes into the signed-in account. Returns how many
  /// moved. [guestAccessToken] proves the caller held the guest account.
  Future<int> claimGuestMinutes(String guestAccessToken);

  /// Deletes the signed-in account and every minute it holds.
  Future<void> deleteAccount();
}
