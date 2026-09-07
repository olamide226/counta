import '../counting/counting_engine.dart';
import 'app_settings.dart';
import 'count_session.dart';
import 'counter_state.dart';

/// Builds the one `CountSession` shape the app writes, for both a checkpoint
/// and a session the user saves by hand.
///
/// The two used to be assembled separately from the same sixteen fields and
/// had already drifted: the checkpoint labelled every session 'Recovered
/// session' and could not carry notes. Keeping one builder also keeps the
/// voice/tap nullability rule — the split is only meaningful when a phrase was
/// being counted — in a single place.
CountSession buildSessionRecord({
  String? id,
  required String mantra,
  required AppSettings settings,
  required CounterState counter,
  required PhraseSpec? phrase,
  required int voiceCount,
  required int manualCount,
  required DateTime endedAt,
  String? notes,
  bool completed = true,
}) {
  final isVoiceSession = phrase != null;

  return CountSession(
    id: id,
    mantra: mantra,
    startedAt: counter.sessionStart,
    endedAt: endedAt,
    // The split is authoritative: decrementing past the manual counts eats
    // into the voice counts, so the sum is the total by construction.
    finalCount: voiceCount + manualCount,
    threshold: counter.threshold,
    repeatInterval: counter.repeatInterval,
    soundMode: settings.soundMode,
    themeModeChoice: settings.themeModeChoice,
    themeId: settings.themeId,
    notes: notes,
    phrase: phrase?.raw,
    voiceCount: isVoiceSession ? voiceCount : null,
    manualCount: isVoiceSession ? manualCount : null,
    completed: completed,
  );
}
