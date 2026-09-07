import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/sound_mode_presentation.dart';

import '../../core/config/build_config.dart';
import '../../state/providers/session_controller.dart';
import '../../state/providers/app_lifecycle_provider.dart';
import '../../state/providers/counter_provider.dart';
import '../../state/providers/services_provider.dart';
import '../../domain/models/count_session.dart';
import '../../state/providers/session_recovery.dart';
import '../../state/providers/settings_provider.dart';
import '../sheets/alert_config_sheet.dart';
import '../sheets/microphone_denied_dialog.dart';
import '../sheets/recover_session_sheet.dart';
import '../sheets/save_session_sheet.dart';
import '../sheets/sound_mode_sheet.dart';
import '../sheets/voice_disclosure_sheet.dart';
import '../widgets/count_display.dart';
import '../widgets/quick_controls_bar.dart';
import '../widgets/resizable_tap_layout.dart';
import '../widgets/tap_zone.dart';
import '../widgets/voice_session_banner.dart';
import 'phrase_setup_screen.dart';
import 'sessions_screen.dart';
import 'settings_screen.dart';
import 'debug/streaming_debug_screen.dart';

class CounterScreen extends ConsumerStatefulWidget {
  const CounterScreen({super.key});

  @override
  ConsumerState<CounterScreen> createState() => _CounterScreenState();
}

class _CounterScreenState extends ConsumerState<CounterScreen>
    with WidgetsBindingObserver {
  ProviderSubscription<AsyncValue<CountSession?>>? _recoverySubscription;
  bool _recoveryOffered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Independent of recovery. Awaiting these used to hold the sheet behind
    // two platform round-trips, during which a tap could land on a session
    // the user had not decided about yet.
    unawaited(_initNotifications());

    // The screen only reacts: taking the checkpoint and attaching the
    // checkpointer are `sessionStartupProvider`'s job, done in app
    // composition before this screen exists.
    _recoverySubscription = ref.listenManual<AsyncValue<CountSession?>>(
      sessionStartupProvider,
      (_, next) => _offerRecovery(next),
      fireImmediately: true,
    );
  }

  Future<void> _initNotifications() async {
    final ns = ref.read(notificationServiceProvider);
    await ns.init();
    await ns.cancelAllNotifications();
  }

  void _offerRecovery(AsyncValue<CountSession?> startup) {
    if (_recoveryOffered) return;
    final checkpoint = startup.valueOrNull;
    if (checkpoint == null) return;
    _recoveryOffered = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showRecoverSessionSheet(context, checkpoint);
    });
  }

  @override
  void dispose() {
    _recoverySubscription?.close();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ref.read(appLifecycleProvider.notifier).handleLifecycleChange(state);
  }

  Future<void> _openPhraseSetup(
    BuildContext context,
    SessionController sessionController,
  ) async {
    // The third-party audio disclosure gates the very first voice session.
    // It is shown before phrase setup so accepting it is a deliberate step,
    // not something buried behind the start button.
    if (!ref.read(settingsProvider).voiceDisclosureSeen) {
      final accepted = await showVoiceDisclosureSheet(context);
      if (!accepted || !mounted) return;
      await ref.read(settingsProvider.notifier).markVoiceDisclosureSeen();
    }
    if (!context.mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PhraseSetupScreen(
          initialPhrase: sessionController.activePhrase?.raw,
          onStartSession: (phraseSpec) async {
            sessionController.setEngine(ref.read(voiceEngineFactoryProvider)());
            await sessionController.startSession(phraseSpec);
            if (sessionController.isPermissionDenied) {
              await _handleMicrophoneDenied(sessionController);
            }
          },
        ),
      ),
    );
  }

  /// The engine refused to start because the microphone was not granted. No
  /// socket was opened, so there is nothing to tear down beyond handing the
  /// count back to the tap engine and telling the user where the fix lives.
  Future<void> _handleMicrophoneDenied(
    SessionController sessionController,
  ) async {
    sessionController.setEngine(ref.read(tapEngineFactoryProvider)());
    if (!mounted) return;
    await showMicrophoneDeniedDialog(
      context,
      onOpenSettings: () =>
          ref.read(microphonePermissionServiceProvider).openSystemSettings(),
    );
  }

  Future<void> _stopVoiceSession(SessionController sessionController) async {
    try {
      await sessionController.stop();
    } finally {
      // Revert engine to TapCountingEngine even if teardown complained, so the
      // app is never left holding a dead cloud engine.
      sessionController.setEngine(ref.read(tapEngineFactoryProvider)());
    }

    // Clear all notifications — the voice session notification and any stale
    // resume notifications from a previous session.
    await ref.read(notificationServiceProvider).cancelAllNotifications();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Voice capture paused'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final counter = ref.watch(counterProvider);
    final settings = ref.watch(settingsProvider);
    final sessionController = ref.watch(sessionControllerProvider);

    final isVoiceActive = sessionController.isVoiceActive;
    final scheme = Theme.of(context).colorScheme;

    // Mirror the screen wakelock to session state here rather than at the call
    // sites, so a session that ends by erroring out releases it too.
    ref.listen<SessionController>(sessionControllerProvider, (prev, next) {
      final wasActive = prev?.isVoiceActive ?? false;
      if (wasActive == next.isVoiceActive) return;

      ref.read(screenWakeServiceProvider).setActive(next.isVoiceActive);
      if (!next.isVoiceActive) {
        ref.read(notificationServiceProvider).cancelVoiceSessionNotification();
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text(BuildConfig.appName),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(
              isVoiceActive
                  ? Icons.stop_circle_outlined
                  : Icons.mic_none_rounded,
              color: isVoiceActive ? scheme.error : null,
            ),
            tooltip: isVoiceActive
                ? 'Stop voice counting'
                : 'Start voice counting',
            onPressed: () {
              if (isVoiceActive) {
                _stopVoiceSession(sessionController);
              } else {
                _openPhraseSetup(context, sessionController);
              }
            },
          ),
          // Dev builds only: this screen exposes a Deepgram API key field and
          // raw transcripts, neither of which belongs in a release.
          if (BuildConfig.showDebugTools)
            IconButton(
              icon: const Icon(Icons.bug_report),
              tooltip: 'Voice Streaming Debug',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const StreamingDebugScreen()),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SessionsScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (isVoiceActive)
              VoiceSessionBanner(
                status: sessionController.status,
                phrase: sessionController.activePhrase?.raw ?? 'Voice session',
                voiceCount: sessionController.voiceCount,
                manualCount: sessionController.manualCount,
                diagnostic: sessionController.lastDiagnostic,
                onStop: () => _stopVoiceSession(sessionController),
              ),
            Expanded(
              child: ResizableTapLayout(
                tapChild: TapZone(
                  onTap: () => ref.read(counterProvider.notifier).increment(),
                ),
                infoChild: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CountDisplay(count: counter.count),
                      const SizedBox(height: 16),
                      QuickControlsBar(
                        onReset: () => _handleReset(
                          context,
                          ref,
                          sessionController,
                          settings.confirmReset,
                        ),
                        onUndo: () =>
                            ref.read(counterProvider.notifier).decrement(),
                        onSave: () => showSaveSessionSheet(context),
                        onAlertConfig: () => showAlertConfigSheet(context),
                        onSoundMode: () => showSoundModeSheet(context),
                        soundModeIcon: settings.soundMode.icon,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleReset(
    BuildContext context,
    WidgetRef ref,
    SessionController sessionController,
    bool confirmReset,
  ) {
    if (confirmReset) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Reset Count?'),
          content: const Text('This will reset your current count to zero.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                ref.read(counterProvider.notifier).reset();
                Navigator.of(context).pop();
              },
              child: const Text('Reset'),
            ),
          ],
        ),
      );
    } else {
      ref.read(counterProvider.notifier).reset();
    }
  }
}
