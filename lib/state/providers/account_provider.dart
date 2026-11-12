import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/app_env.dart';
import '../../core/services/account/account_service.dart';
import '../../core/services/account/native_identity_source.dart';
import '../../core/services/account/supabase_auth_gateway.dart';
import '../../domain/account/account.dart';
import 'counter_provider.dart';
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

/// How a sign-out or delete went.
enum AccountAction { done, failed, voiceRunning }

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
      // A token refresh reports the same account again; nothing to redraw.
      if (mounted && status != state.status) {
        state = state.copyWith(status: status);
      }
    });
  }

  Future<SignInResult> signIn(SignInMethod method) => _guarded(
    unavailable: const SignInFailed(),
    voiceRunning: const SignInFailed(voiceRunningMessage),
    action: (service) async {
      final result = await service.signIn(method);
      if (result is SignInSucceeded && result.returning) _afterSwitch();
      return result;
    },
  );

  Future<AccountAction> signOut() => _switch((s) => s.signOut());

  /// Fails, changing nothing, when the server could not delete the account.
  Future<AccountAction> deleteAccount() => _switch((s) => s.deleteAccount());

  Future<AccountAction> _switch(Future<void> Function(AccountService) action) =>
      _guarded(
        unavailable: AccountAction.failed,
        voiceRunning: AccountAction.voiceRunning,
        action: (service) async {
          try {
            await action(service);
          } catch (error) {
            debugPrint('Account action failed: $error');
            return AccountAction.failed;
          }
          _afterSwitch();
          return AccountAction.done;
        },
      );

  /// Runs one account action at a time, and none under a running voice
  /// session: it holds a block bought by the account in use.
  Future<T> _guarded<T>({
    required T unavailable,
    required T voiceRunning,
    required Future<T> Function(AccountService) action,
  }) async {
    final service = _service;
    if (service == null || state.busy) return unavailable;
    if (_ref.read(sessionControllerProvider).isVoiceActive) return voiceRunning;
    state = state.copyWith(busy: true);
    try {
      return await action(service);
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
    controller.attach(
      AccountService(
        auth: SupabaseAuthGateway(
          Supabase.instance.client.auth,
          accessToken: () => liveAccessToken(ref),
        ),
        identity: NativeIdentitySource(
          googleWebClientId: AppEnv.googleWebClientId,
          googleIosClientId: AppEnv.googleIosClientId.isEmpty
              ? null
              : AppEnv.googleIosClientId,
        ),
        backend: ref.read(blockClientProvider),
      ),
    );
  }, fireImmediately: true);
  return controller;
});
