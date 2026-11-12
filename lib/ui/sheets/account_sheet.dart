import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../domain/account/account.dart';
import '../../state/providers/account_provider.dart';
import '../widgets/account_dialogs.dart';
import '../widgets/voice_minutes_widgets.dart';
import 'counta_sheet.dart';

/// Opens the account sheet. Shows what happened afterwards as a snack bar
/// on [context], so the person sees the outcome where they started.
Future<void> showAccountSheet(BuildContext context) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final message = await showCountaSheet<String>(
    context: context,
    builder: (_) => const AccountSheet(),
  );
  if (message != null) {
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Sign in to keep voice minutes, or manage the account once signed in.
///
/// One screen, two states, no forms: a guest sees the Apple and Google
/// buttons; a signed-in person sees who they are, sign out and delete.
class AccountSheet extends ConsumerStatefulWidget {
  const AccountSheet({super.key});

  @override
  ConsumerState<AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends ConsumerState<AccountSheet> {
  String? _error;

  /// Which button is working, so only that one shows a spinner.
  SignInMethod? _pending;

  Future<void> _signIn(SignInMethod method) async {
    setState(() {
      _error = null;
      _pending = method;
    });
    final result = await ref.read(accountProvider.notifier).signIn(method);
    if (!mounted) return;
    setState(() => _pending = null);
    switch (result) {
      case SignInCancelled():
        break;
      case SignInFailed(:final message):
        setState(() => _error = message);
      case SignInSucceeded():
        Navigator.of(context).pop(_successMessage(result));
    }
  }

  static String _successMessage(SignInSucceeded result) {
    if (!result.returning) return 'Signed in. Your minutes are safe.';
    if (result.moveFailed) {
      return "Welcome back. This phone's minutes couldn't be added yet — "
          'email hello@ruac.tech and we will add them.';
    }
    if (result.movedMinutes > 0) {
      return 'Welcome back. ${minutesCount(result.movedMinutes)} from this '
          'phone were added to your account.';
    }
    return 'Welcome back. Your minutes are ready.';
  }

  Future<void> _signOut() async {
    if (!await confirmSignOut(context)) return;
    _finish(
      await ref.read(accountProvider.notifier).signOut(),
      done: 'Signed out.',
      failed: "Couldn't sign out. Please try again.",
    );
  }

  Future<void> _delete() async {
    if (!await confirmDeleteAccount(context)) return;
    _finish(
      await ref.read(accountProvider.notifier).deleteAccount(),
      done: 'Your account was deleted.',
      failed:
          "Couldn't delete your account. Check your connection and try again.",
    );
  }

  void _finish(
    AccountAction outcome, {
    required String done,
    required String failed,
  }) {
    if (!mounted) return;
    switch (outcome) {
      case AccountAction.done:
        Navigator.of(context).pop(done);
      case AccountAction.failed:
        setState(() => _error = failed);
      case AccountAction.voiceRunning:
        setState(() => _error = voiceRunningMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    return SingleChildScrollView(
      child: CountaSheetBody(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded),
              tooltip: 'Close',
            ),
          ),
          ...switch (account.status) {
            GuestAccount() => _guest(context, account),
            SignedInAccount status => _signedIn(context, account, status),
          },
          if (_error case final error?) ...[
            const SizedBox(height: 12),
            SheetMessage(text: error, isError: true),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  List<Widget> _guest(BuildContext context, AccountState account) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final idle = !account.busy;

    return [
      Center(
        child: CircleAvatar(
          radius: 28,
          backgroundColor: scheme.primaryContainer,
          child: Icon(
            Icons.cloud_done_outlined,
            size: 28,
            color: scheme.onPrimaryContainer,
          ),
        ),
      ),
      const SizedBox(height: 16),
      Text(
        'Keep your minutes safe',
        textAlign: TextAlign.center,
        style: theme.textTheme.headlineSmall,
      ),
      const SizedBox(height: 8),
      Text(
        'Sign in and your voice minutes are saved to your account, ready on '
        'any phone.',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 24),
      for (final method in account.methods) ...[
        SizedBox(
          height: 50,
          child: _pending == method
              ? const Center(child: CircularProgressIndicator())
              : switch (method) {
                  SignInMethod.apple => SignInWithAppleButton(
                    text: 'Continue with Apple',
                    height: 50,
                    borderRadius: const BorderRadius.all(Radius.circular(25)),
                    style: dark
                        ? SignInWithAppleButtonStyle.white
                        : SignInWithAppleButtonStyle.black,
                    onPressed: idle ? () => _signIn(method) : () {},
                  ),
                  SignInMethod.google => OutlinedButton(
                    onPressed: idle ? () => _signIn(method) : null,
                    style: OutlinedButton.styleFrom(
                      shape: const StadiumBorder(),
                      textStyle: theme.textTheme.titleMedium,
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _GoogleMark(),
                        SizedBox(width: 10),
                        Text('Continue with Google'),
                      ],
                    ),
                  ),
                },
        ),
        const SizedBox(height: 12),
      ],
      const SizedBox(height: 4),
      Text(
        'Your counts and sessions stay on this phone.',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    ];
  }

  List<Widget> _signedIn(
    BuildContext context,
    AccountState account,
    SignedInAccount status,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return [
      Text('Account', style: theme.textTheme.headlineSmall),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(Icons.verified_user_outlined, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(status.title, style: theme.textTheme.titleMedium),
                  Text(
                    _displayEmail(status.email) ??
                        'Your voice minutes are saved to this account.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      if (account.busy)
        const Center(child: CircularProgressIndicator())
      else ...[
        OutlinedButton(
          onPressed: _signOut,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: const Text('Sign out'),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: _delete,
          style: TextButton.styleFrom(foregroundColor: scheme.error),
          child: const Text('Delete account'),
        ),
      ],
    ];
  }

  /// Apple's "hide my email" relay address means nothing to the person who
  /// chose it, so it is not shown.
  static String? _displayEmail(String? email) {
    if (email == null || email.endsWith('privaterelay.appleid.com')) {
      return null;
    }
    return email;
  }
}

/// Google's four-colour "G", drawn rather than shipped as an asset.
class _GoogleMark extends StatelessWidget {
  const _GoogleMark();

  @override
  Widget build(BuildContext context) =>
      const SizedBox.square(dimension: 20, child: CustomPaint(painter: _G()));
}

class _G extends CustomPainter {
  const _G();

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.2;
    final rect =
        Offset(stroke / 2, stroke / 2) &
        Size(size.width - stroke, size.height - stroke);
    Paint arc(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    const deg = 3.1415926535 / 180;
    canvas.drawArc(
      rect,
      -40 * deg,
      -100 * deg,
      false,
      arc(const Color(0xFFEA4335)),
    );
    canvas.drawArc(
      rect,
      -140 * deg,
      -90 * deg,
      false,
      arc(const Color(0xFFFBBC05)),
    );
    canvas.drawArc(
      rect,
      130 * deg,
      -90 * deg,
      false,
      arc(const Color(0xFF34A853)),
    );
    canvas.drawArc(
      rect,
      40 * deg,
      -40 * deg,
      false,
      arc(const Color(0xFF4285F4)),
    );
    canvas.drawRect(
      Rect.fromLTWH(
        size.width / 2,
        size.height / 2 - stroke / 2,
        size.width / 2 - stroke / 4,
        stroke,
      ),
      Paint()..color = const Color(0xFF4285F4),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
