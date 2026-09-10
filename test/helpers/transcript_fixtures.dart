import 'package:counta/domain/counting/counting_engine.dart';
import 'package:counta/domain/counting/transcript_segment.dart';

/// The segment builder and target phrase every voice test speaks in.
///
/// Split out of `voice_fakes.dart` because that file reaches the `record`
/// plugin through `AudioSource`, and the `domain/` tests must not — which is
/// why they had grown a spelling of this builder of their own. Nothing here
/// imports anything but the domain.

/// One finalised transcript segment, on a connection's own audio timeline.
///
/// `start` is where the connection heard it, not where the session did: every
/// Deepgram connection numbers its own audio from zero, and rebasing that
/// onto the session timeline is the matcher's job.
TranscriptSegment finalSegment(
  String text, {
  double start = 1.0,
  double duration = 2.0,
  double confidence = 0.98,
}) => TranscriptSegment(
  text: text,
  start: start,
  duration: duration,
  isFinal: true,
  confidence: confidence,
);

const testPhrase = PhraseSpec(
  raw: "I'm rich in wisdom",
  normalisedTokens: ['i', 'am', 'rich', 'in', 'wisdom'],
);
