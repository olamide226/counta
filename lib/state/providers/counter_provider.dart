import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'session_controller.dart';
import '../../core/config/build_config.dart';
import '../../core/config/dev_secrets.dart';
import '../../core/services/counting/cloud_counting_engine.dart';
import '../../core/services/counting/tap_counting_engine.dart';
import '../../domain/counting/counting_engine.dart';
import '../../domain/models/count_session.dart';
import '../../domain/models/counter_state.dart';
import 'services_provider.dart';
import 'settings_provider.dart';
import 'supabase_providers.dart';

final sessionControllerProvider = ChangeNotifierProvider<SessionController>(
  (ref) => SessionController(
    liveActivityService: ref.watch(liveActivityServiceProvider),
    voiceEngineFactory: ref.watch(voiceEngineFactoryProvider),
    tapEngineFactory: ref.watch(tapEngineFactoryProvider),
  ),
);

/// Supplies the Deepgram credential when there is no block service.
///
/// The fallback for a build with no Supabase configuration: a dev key, or
/// [VoiceUnavailable] when even that is missing. The engine turns that into
/// [EngineStatus.notConfigured] and the UI shows the message — an unhandled
/// async error here failed every voice session with nothing on screen to say
/// why. A configured build never reaches this: its credential arrives with a
/// block from [blockServiceProvider], which is the only path that can pay for
/// streaming time.
///
/// The [DevSecrets] read is compile-time dead in release, because
/// [BuildConfig.showDebugTools] is a constant.
final deepgramTokenProviderProvider = Provider<DeepgramTokenProvider>(
  (ref) => () async {
    if (!BuildConfig.showDebugTools) {
      throw const VoiceUnavailable(
        'Voice counting needs a block token from the voice-block service, '
        'which is not wired into this build yet.',
      );
    }
    final key = DevSecrets.deepgramApiKey;
    if (key == null) {
      throw const VoiceUnavailable(
        'DEEPGRAM_API_KEY is not set. Add it to .env or pass '
        '--dart-define=DEEPGRAM_API_KEY=... for dev voice sessions.',
      );
    }
    return key;
  },
);

/// Builds the engine for a voice session.
///
/// Exists so screens never construct a microphone + WebSocket stack
/// themselves — that made the counter screen untestable and put platform
/// wiring in the UI layer.
final voiceEngineFactoryProvider = Provider<CountingEngine Function()>((ref) {
  final blocks = ref.watch(blockServiceProvider);
  // Exactly one credential source. A configured build pays for its streaming
  // time; falling back to a dev key when the block service is present would
  // be a way to stream without paying — so the fallback is not even built.
  final devToken = blocks == null
      ? ref.read(deepgramTokenProviderProvider)
      : null;
  return () =>
      CloudCountingEngine(blockService: blocks, tokenProvider: devToken);
});

/// Builds the engine used when no voice session is running.
final tapEngineFactoryProvider = Provider<CountingEngine Function()>(
  (ref) => TapCountingEngine.new,
);

final counterProvider = StateNotifierProvider<CounterNotifier, CounterState>(
  (ref) => CounterNotifier(
    ref,
    sessionController: ref.read(sessionControllerProvider),
  ),
);

class CounterNotifier extends StateNotifier<CounterState> {
  final Ref _ref;
  final SessionController sessionController;

  CounterNotifier(this._ref, {required this.sessionController})
    : super(CounterState(count: 0, sessionStart: DateTime.now())) {
    _initFromSettings();
    sessionController.addListener(_onSessionChanged);
  }

  void _onSessionChanged() {
    if (state.count != sessionController.total) {
      state = state.copyWith(count: sessionController.total);
    }
  }

  void _initFromSettings() {
    final settings = _ref.read(settingsProvider);
    state = state.copyWith(
      threshold: settings.defaultThreshold,
      repeatInterval: settings.defaultRepeatInterval,
    );
  }

  Future<void> increment() async {
    final previousCount = state.count;
    // incrementManual notifies synchronously, so _onSessionChanged has already
    // written the new count into state — the controller is the single owner.
    sessionController.incrementManual();
    final newCount = sessionController.total;

    // Check and trigger alert
    final alertService = _ref.read(alertServiceProvider);
    final shouldAlert = alertService.shouldAlert(
      previousCount: previousCount,
      newCount: newCount,
      threshold: state.threshold,
      repeatInterval: state.repeatInterval,
    );

    if (shouldAlert) {
      await alertService.triggerAlert();
    }

    // Play tap feedback
    final settings = _ref.read(settingsProvider);
    final tapService = _ref.read(tapFeedbackServiceProvider);
    await tapService.playTapFeedback(settings.soundMode);
  }

  Future<void> decrement() async {
    if (state.count <= 0) return; // Prevent negative counts

    sessionController.decrementManual();

    // Play light haptic for undo
    final settings = _ref.read(settingsProvider);
    final tapService = _ref.read(tapFeedbackServiceProvider);
    await tapService.playTapFeedback(settings.soundMode);
  }

  void reset({bool keepSessionStart = false}) {
    sessionController.reset(keepSessionStart: keepSessionStart);
    state = state.copyWith(
      count: 0,
      sessionStart: keepSessionStart ? state.sessionStart : DateTime.now(),
    );
  }

  void setThreshold(int? value) {
    state = state.copyWith(threshold: value);
  }

  void setRepeatInterval(int? value) {
    state = state.copyWith(repeatInterval: value);
  }

  void startNewSession() {
    sessionController.reset(keepSessionStart: false);
    state = state.copyWith(count: 0, sessionStart: DateTime.now());
  }

  void loadSession(CountSession session) {
    // Restore rather than reset: the controller owns the running total, so
    // leaving it at zero here made the next tap collapse the loaded count to 1.
    // Restoring also brings back the voice/tap split and the phrase, so a
    // recovered voice session carries on as one.
    sessionController.restore(session);
    state = CounterState(
      count: session.finalCount,
      mantra: session.mantra,
      threshold: session.threshold,
      repeatInterval: session.repeatInterval,
      sessionStart: session.startedAt,
    );
  }

  @override
  void dispose() {
    sessionController.removeListener(_onSessionChanged);
    super.dispose();
  }
}
