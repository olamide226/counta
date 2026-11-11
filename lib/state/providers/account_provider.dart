import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/app_env.dart';
import '../../core/services/account/account_service.dart';
import '../../core/services/account/native_identity_source.dart';
import '../../core/services/account/supabase_auth_gateway.dart';
import '../../domain/account/account.dart';
import 'minute_store_provider.dart';
import 'supabase_providers.dart';
import 'voice_minutes_provider.dart';

/// What the account screens show.
@immutable
class AccountState {
  const AccountState({
    this.status = const GuestAccount(),
    this.methods = const [],
    this.busy = false,
  });

  final AccountStatus status;

  /// The sign-in buttons this build can offer, in the order shown. Empty means
  /// signing in is not offered at all.
  final List<SignInMethod> methods;

  /// A sign-in, sign-out or delete is in flight.
  final bool busy;

  bool get available => methods.isNotEmpty;
  bool get isGuest => status is GuestAccount;

  AccountState copyWith({AccountStatus? status, bool? busy}) => AccountState(
    status: status ?? this.status,
    methods: methods,
    busy: busy ?? this.busy,
  );
}

class AccountController extends StateNotifier<AccountState> {
  AccountController(this._ref, List<SignInMethod> methods)
    : super(AccountState(methods: methods));

  final Ref _ref;
  AccountService? _service;
  StreamSubscription<AccountStatus>? _changes;

  /// Called once the Supabase session exists.
  void attach(AccountService service) {
    if (_service != null) return;
    _service = service;
    state = state.copyWith(status: service.status);
    _changes = service.changes.listen((status) {
      if (mounted) state = state.copyWith(status: status);
    });
  }

  Future<SignInResult> signIn(SignInMethod method) async {
    final service = _service;
    if (service == null || state.busy) return const SignInFailed();
    state = state.copyWith(busy: true);
    try {
      final minutes = _ref.read(voiceMinutesProvider);
      final result = await service.signIn(
        method,
        // Unknown counts as "has some": moving nothing costs one call, while
        // skipping a move that was needed would lose minutes.
        guestHasMinutes: (minutes.balance ?? 1) > 0,
      );
      if (result is SignInSucceeded && result.returning) _afterSwitch();
      return result;
    } finally {
      if (mounted) state = state.copyWith(busy: false);
    }
  }

  /// Returns false when it could not finish.
  Future<bool> signOut() => _run((service) => service.signOut());

  /// Returns false when the account could not be deleted; nothing changed then.
  Future<bool> deleteAccount() => _run((service) => service.deleteAccount());

  Future<bool> _run(Future<void> Function(AccountService) action) async {
    final service = _service;
    if (service == null || state.busy) return false;
    state = state.copyWith(busy: true);
    try {
      await action(service);
      _afterSwitch();
      return true;
    } catch (error) {
      debugPrint('Account action failed: $error');
      return false;
    } finally {
      if (mounted) state = state.copyWith(busy: false);
    }
  }

  /// A different account is now signed in: its balance and its store
  /// customer replace the old ones.
  void _afterSwitch() {
    unawaited(_ref.read(voiceMinutesProvider.notifier).refresh());
    _ref.invalidate(minutePacksProvider);
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }
}

/// The sign-in buttons this build offers. Apple first on iPhone, as Apple
/// asks; Google wherever it is configured.
List<SignInMethod> _offeredMethods() => [
  if (AppEnv.hasAppleSignIn) SignInMethod.apple,
  if (AppEnv.hasGoogleSignIn) SignInMethod.google,
];

final accountProvider = StateNotifierProvider<AccountController, AccountState>((
  ref,
) {
  final methods = AppEnv.hasSupabase ? _offeredMethods() : <SignInMethod>[];
  final controller = AccountController(ref, methods);
  if (methods.isEmpty) return controller;

  ref.listen(supabaseSessionProvider, (_, next) {
    if (!next.hasValue || next.value == null) return;
    final backend = ref.read(blockServiceProvider);
    controller.attach(
      AccountService(
        auth: SupabaseAuthGateway(Supabase.instance.client.auth),
        identity: NativeIdentitySource(
          googleWebClientId: AppEnv.googleWebClientId,
          googleIosClientId: AppEnv.googleIosClientId.isEmpty
              ? null
              : AppEnv.googleIosClientId,
        ),
        backend: backend is AccountBackend ? backend as AccountBackend : null,
      ),
    );
  }, fireImmediately: true);
  return controller;
});
