import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/sound_mode_presentation.dart';

import '../../core/config/build_config.dart';
import '../../state/providers/hive_providers.dart';
import '../../state/providers/session_controller.dart';
import '../../state/providers/app_lifecycle_provider.dart';
import '../../state/providers/counter_provider.dart';
import '../../state/providers/services_provider.dart';
import '../../core/services/microphone_settings.dart';
import '../../domain/counting/block_service.dart';
import '../../domain/counting/counting_engine.dart';
import '../../domain/models/count_session.dart';
import '../../state/providers/session_recovery.dart';
import '../../state/providers/settings_provider.dart';
import '../../state/providers/voice_minutes_provider.dart';
import '../sheets/alert_config_sheet.dart';
import '../sheets/recover_session_sheet.dart';
import '../sheets/save_session_sheet.dart';
import '../sheets/sound_mode_sheet.dart';
import '../sheets/voice_minutes_sheet.dart';
import '../widgets/count_display.dart';
import '../widgets/microphone_denied_dialog.dart';
import '../widgets/quick_controls_bar.dart';
import '../widgets/resizable_tap_layout.dart';
import '../widgets/tap_zone.dart';
import '../widgets/voice_minutes_widgets.dart';
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

  void _openPhraseSetup(
    BuildContext context,
    SessionController sessionController,
  ) {
    // Read before the route is pushed: the callbacks below run across awaits,
    // and reaching for a provider after one is how a screen that has since
    // been popped throws instead of recording anything.
    final history = ref.read(phraseHistoryRepositoryProvider);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PhraseSetupScreen(
          initialPhrases: sessionController.activePhrases?.rawPhrases,
          recentPhrases: history.getRecent(),
          // The controller owns the whole voice lifecycle — disclosure,
          // engine swap, and the fallback to tap counting when the engine
          // cannot run. The screen only reacts to how it ended.
          onStartSession: (phrases) async {
            final outcome = await sessionController.startVoiceSession(phrases);
            if (outcome == EngineStatus.permissionDenied) {
              await _handleMicrophoneDenied();
            }
            // Remembered only once a session really started, so a setup
            // that failed on permissions, credit or configuration does not
            // come back as a suggestion. Asked positively: the exclusion
            // form counted `notConfigured` — a build that can never obtain a
            // credential — as a successful start.
            if (SessionController.runningStatuses.contains(outcome)) {
              // Best effort. A suggestion that cannot be stored must not
              // surface as "could not start voice counting" over a session
              // that is running perfectly well.
              try {
                await history.record(phrases);
              } catch (_) {}
            }
          },
        ),
      ),
    );
  }

  /// The engine refused to start because the microphone was not granted. The
  /// controller has already handed the count back to the tap engine, so all
  /// that is left is telling the user where the fix lives.
  Future<void> _handleMicrophoneDenied() async {
    if (!mounted) return;
    await showMicrophoneDeniedDialog(
      context,
      onOpenSettings: openMicrophoneSettings,
    );
  }

  Future<void> _stopVoiceSession(SessionController sessionController) async {
    await sessionController.stopVoiceSession();

    // Clear all notifications — the voice session notification and any stale
    // resume notifications from a previous session.
    await ref.read(notificationServiceProvider).cancelAllNotifications();

    if (!mounted) return;

    // A stop that reported what it cost says so in the banner's place, and
    // that line already tells the user voice counting has stopped.
    if (ref.read(voiceMinutesProvider).lastUsage != null) return;

    _say('Voice capture paused');
  }

  void _say(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _dismissOutOfMinutes(SessionController sessionController) {
    sessionController.dismissOutOfMinutes();
    // Its receipt would otherwise appear in the same place a moment later,
    // for a session the user has just waved away.
    ref.read(voiceMinutesProvider.notifier).clearLastUsage();
  }

  /// Opens the minutes sheet from a session that ran out, and picks the
  /// session back up if the user asks for that once they have minutes.
  Future<void> _getMinutesAndResume(SessionController sessionController) async {
    final resume = await showVoiceMinutesSheet(
      context,
      resumeLabel: 'Resume voice counting',
      successNote: 'Your count is where you left it.',
      dismissLabel: 'Keep counting by tapping',
    );
    if (resume != true || !mounted) return;

    final phrases = sessionController.activePhrases;
    if (phrases == null) {
      _openPhraseSetup(context, sessionController);
      return;
    }

    try {
      final outcome = await sessionController.startVoiceSession(phrases);
      if (outcome == EngineStatus.permissionDenied) {
        await _handleMicrophoneDenied();
      }
    } on BlockFailure catch (failure) {
      if (mounted) _say(failure.message);
    } catch (_) {
      if (mounted) _say("Couldn't start voice counting. Please try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final counter = ref.watch(counterProvider);
    final settings = ref.watch(settingsProvider);
    final sessionController = ref.watch(sessionControllerProvider);
    final minutes = ref.watch(voiceMinutesProvider);

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
                phrases:
                    sessionController.activePhrases?.rawPhrases ??
                    const ['Voice session'],
                voiceCount: sessionController.voiceCount,
                manualCount: sessionController.manualCount,
                phraseCounts: sessionController.voiceCountsByPhrase,
                lastMatchedPhrase: sessionController.lastVoicePhrase,
                diagnostic: sessionController.lastDiagnostic,
                minutesLeft: minutes.available ? minutes.left : null,
                minutesLow: minutes.isLow,
                onStop: () => _stopVoiceSession(sessionController),
              )
            else if (sessionController.outOfMinutes)
              VoicePausedBanner(
                voiceCount: sessionController.voiceCount,
                manualCount: sessionController.manualCount,
                onGetMinutes: () => _getMinutesAndResume(sessionController),
                onDismiss: () => _dismissOutOfMinutes(sessionController),
              )
            else if (minutes.lastUsage case final usage?)
              VoiceUsageStrip(
                // Keyed by the figures so a second stop restarts its timer
                // rather than inheriting what was left of the first one's.
                key: ValueKey((usage.used, usage.returned, usage.left)),
                usage: usage,
                onDismiss: ref
                    .read(voiceMinutesProvider.notifier)
                    .clearLastUsage,
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
