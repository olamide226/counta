# Design Document

## Overview

Voice phrase counting adds cloud streaming speech recognition to the existing tap counter. The design has one governing constraint: **accuracy is the reason for choosing cloud STT, and per-minute cost is the price of that choice.** Every architectural decision below follows from bounding that cost without operating infrastructure.

The design deliberately avoids a server-side audio relay. Deepgram supports short-lived tokens for direct client connections, and RevenueCat provides virtual currency balance management, so the entire server-side footprint is one Supabase Edge Function and one small table. The Flutter client owns audio capture, the Deepgram WebSocket, and phrase matching.

This trades away three things a relay would give: a hard mid-stream kill switch, server-side matcher tuning, and transcript telemetry by default. Each is mitigated below (block granularity, remote config, opt-in diagnostics). The engine abstraction in the client is shaped so that introducing a relay later is a swap of one collaborator rather than a rewrite.

---

## Architecture

### System context

```
┌─────────────────────────────────────────────┐
│  Flutter app                                │
│                                             │
│  CountingEngine (interface)                 │
│   ├── TapCountingEngine    (existing)       │
│   └── CloudCountingEngine  (new)            │
│        ├── BlockClient                      │
│        ├── AudioSource                      │
│        ├── DeepgramSocket                   │
│        └── PhraseMatcher   (pure, testable) │
│                                             │
│  SessionController → SessionRepository      │
│  EntitlementService (RevenueCat SDK)        │
└────┬──────────────────────┬─────────────────┘
     │ HTTPS                │ WSS (audio out, transcripts in)
     │                      │
     ▼                      ▼
┌─────────────────┐   ┌──────────────┐
│ Supabase        │   │  Deepgram    │
│  Edge Function  │   │  /v1/listen  │
│  /voice-block   │   └──────────────┘
│                 │           ▲
│  Postgres:      │           │ mints token
│   voice_blocks  │           │
│   matcher_config│───────────┘
│   trial_grants  │
└────┬────────────┘
     │ Developer API v2 (balance read, spend, grant)
     ▼
┌──────────────┐
│  RevenueCat  │  ← IAP validation, virtual currency ledger
└──────────────┘
```

### Request flow: starting a session

```
1. User declares phrase, taps Start
2. Client → Edge Function: POST /voice-block { session_id }
3. Edge Function:
     verify Supabase JWT
     check no live block for user          → 409 if one exists
     read RevenueCat balance               → 402 if < BLOCK_CREDITS
     spend BLOCK_CREDITS on RevenueCat
     POST Deepgram /v1/auth/grant (ttl=30) → refund + 503 on failure
     insert voice_blocks row
4. Edge Function → Client: { token, block_seconds, expires_at, balance_after }
5. Client opens WSS to Deepgram with Bearer token and keyterm params
6. Client starts AudioSource, pipes PCM frames to socket
7. Transcripts → PhraseMatcher → CountEvent → UI + haptic
8. At 90% of block_seconds: goto 2 (renewal), overlap connections
```

### Why blocks

A client-held WebSocket cannot be terminated by the server that authorised it. Selling streaming time in fixed pre-paid blocks bounds the exposure of that fact to a single block per user. Combined with a hard Deepgram project spend limit (Requirement 10.4), total downside is capped regardless of client behaviour.

Block size of 300 seconds balances three pressures: shorter blocks mean more Edge Function calls and more reconnection seams; longer blocks mean more unused time lost when a user stops mid-block, and a larger abuse window. 300 seconds gives roughly nine renewals across a 45-minute practice, each an invisible overlap.

### Deployment

| Component | Where | Notes |
|---|---|---|
| Edge Function | Supabase Functions (Deno) | Stateless, no cold-start concern for a sub-second HTTP call |
| `voice_blocks`, `matcher_config`, `trial_grants` | Supabase Postgres | RLS on all three |
| Secrets | Supabase function secrets | `DEEPGRAM_API_KEY`, `REVENUECAT_SECRET_KEY`, `REVENUECAT_PROJECT_ID` |
| Auth | Supabase anonymous sign-in | Upgradeable to email later without changing this feature |

---

## Components and Interfaces

### `CountingEngine` (abstraction seam)

The existing tap counter and the new cloud engine implement one interface so `SessionController` is agnostic to which is active. A future relay-backed engine slots in here unchanged from the controller's perspective.

```dart
abstract class CountingEngine {
  Stream<CountEvent>   get counts;
  Stream<EngineStatus> get status;

  Future<void> start(PhraseSpec phrase);
  Future<void> pause();
  Future<void> resume();
  Future<SessionSummary> stop();
  Future<void> dispose();
}

enum EngineStatus {
  idle, requestingBlock, connecting, live,
  reconnecting, degraded, exhausted, error,
}

class CountEvent {
  final int      seq;
  final CountSource source;   // voice | manual
  final double   confidence;  // 1.0 for manual
  final Duration audioOffset;
  final DateTime wallClock;
}

class PhraseSpec {
  final String       raw;
  final List<String> normalisedTokens;
  final List<String> keyterms;
  final String       languageCode;   // 'en' for this iteration
}
```

### `BlockClient`

Owns the credit lifecycle. The only component that talks to the Edge Function.

```dart
class BlockClient {
  Future<Block> acquire(String sessionId);
  Future<void>  release(String blockId, {required bool eligibleForRefund});
  Stream<int>   get balanceUpdates;
}

class Block {
  final String   id;
  final String   deepgramToken;
  final int      blockSeconds;
  final DateTime expiresAt;
  final int      balanceAfter;
}
```

Renewal timing: a timer set at `blockSeconds * 0.9` triggers `acquire()` for the next block. The new Deepgram socket is opened and confirmed before the old one is closed, so no audio is lost at the seam. `AudioSource` frames are written to whichever socket is designated primary; during the overlap window both receive frames, and the matcher deduplicates by audio offset.

The Deepgram token TTL of 30 seconds governs connection establishment only. A socket opened with a valid token remains authorised for its lifetime, which is what makes 300-second blocks workable with a 30-second token.

### `AudioSource`

Wraps `record`'s `startStream()`.

```dart
class AudioSource {
  Stream<Uint8List> start({int sampleRate = 16000});
  Future<void> stop();
}
```

Configuration: 16 kHz, mono, PCM16, which is the format Deepgram's `linear16` encoding expects and the lowest rate that does not degrade recognition. Frames arrive roughly every 100 ms.

**Backpressure policy:** if the socket's send buffer exceeds 2 seconds of audio, drop the oldest frames rather than queueing. An unbounded buffer means the app eventually streams stale audio, and the count visibly lags reality, which users read as the app being broken. Dropped frames are counted and surfaced in diagnostics.

### `DeepgramSocket`

```dart
class DeepgramSocket {
  Future<void> connect(Block block, PhraseSpec phrase);
  void send(Uint8List pcm);
  Stream<TranscriptSegment> get segments;
  Stream<SocketState> get state;
  Future<void> closeGracefully();   // sends CloseStream, drains finals
}
```

Connection parameters:

```dart
final params = {
  'model':            'nova-3',
  'language':         phrase.languageCode,
  'encoding':         'linear16',
  'sample_rate':      '16000',
  'channels':         '1',
  'interim_results':  'true',
  'endpointing':      '300',
  'utterance_end_ms': '1000',
  'no_delay':         'true',
  'smart_format':     'false',
  'punctuate':        'false',
  'numerals':         'false',
  'mip_opt_out':      'true',
  // repeated: keyterm=<each target token or bigram>
};
```

The defaults are tuned for conversational transcription and work against repetition counting. Specific reasoning:

- `smart_format` and `punctuate` off because formatting introduces variance the matcher then has to strip back out.
- `numerals` off because it turns spoken "one" into "1", breaking token comparison for any phrase containing a number word.
- `endpointing: 300` because chanting has minimal inter-repetition silence and the default is too slow to segment it.
- `keyterm` because key term prompting biases Nova-3 toward the supplied terms. This is marginal for common English phrases and decisive for uncommon or non-English ones, which is the direction this feature will grow.

Protocol handling:

- Send `{"type":"KeepAlive"}` every 5 seconds when no audio frames have been sent, to avoid Deepgram's idle disconnect.
- Send `{"type":"CloseStream"}` on graceful shutdown and wait up to 2000 ms for trailing finals before closing the socket.
- Count only on segments with `is_final: true`. Do not use `speech_final`, which fires at endpointing and may not fire for minutes during continuous chanting.

### `PhraseMatcher`

Pure Dart. No network, no audio, no platform channels. This is the component that will change most often and therefore the one that must be testable in `flutter test` against recorded fixtures.

```dart
class PhraseMatcher {
  PhraseMatcher({
    required PhraseSpec target,
    required MatcherConfig config,
  });

  /// Feeds one finalised segment. Returns zero or more detections.
  List<Detection> ingest(TranscriptSegment segment);

  MatcherStats get stats;   // median utterance duration, windows evaluated
}

class MatcherConfig {
  final double threshold;            // default 0.80
  final double refractoryMultiplier; // default 0.60 of median utterance
  final int    refractoryFloorMs;    // default 1200
  final double windowSlack;          // default 1.5 x target token count
  final Map<String, String> homophones;
  final Map<String, String> contractions;
}
```

#### Matching algorithm

```
ingest(segment):
  tokens := normalise(segment.text)
  window.addAll(tokens with their audio offsets)
  trim window to (target.length * windowSlack) tokens

  for each candidate slice in window, longest first:
      score := tokenSimilarity(candidate, target)
      if score >= config.threshold:
          if now - lastMatchAt < refractoryPeriod: skip
          emit Detection(score, candidate.audioOffset)
          consume candidate tokens from window
          lastMatchAt := now
          record utterance duration, update median
          break
```

**Normalisation pipeline**, applied identically to target and to incoming text:

1. Lowercase
2. Strip punctuation and non-word characters
3. Expand contractions from config map (`i'm` to `i am`, `don't` to `do not`)
4. Apply homophone map from config
5. Collapse whitespace, split on whitespace

This is why `"I'm rich in wisdom"`, `"im rich in wisdom"`, and `"i am rich in wisdom"` all score as the same phrase. Deepgram will produce all three across a single session.

**Similarity** is token-level Levenshtein distance normalised to a ratio in [0, 1], not exact string equality. Exact matching fails on the first dropped article.

**The refractory period is the single most important guard.** A sliding window over a token stream will fire two or three times for one utterance without it, inflating counts by 2x to 3x and destroying trust in the number. The period adapts: it starts at `refractoryFloorMs` and, once five utterances have been observed, becomes `median utterance duration * refractoryMultiplier`.

### `SessionController`

Orchestrates the engine, the local count, persistence, and UI state.

```dart
class SessionController extends ChangeNotifier {
  int get total;
  int get voiceCount;
  int get manualCount;
  Duration get elapsed;
  int get remainingCredits;
  EngineStatus get status;

  Future<void> startVoiceSession(PhraseSpec phrase);
  void incrementManual();
  void decrementManual();
  Future<SessionSummary> stop();
}
```

**The local count is authoritative for display.** Detections increment it; they never overwrite it. This is what makes the tally survive a dropped connection, a block renewal failure, or credit exhaustion. Losing a 40-minute tally to a tunnel is the failure that gets an app abandoned.

Checkpointing: the current count is written to local storage every 10 seconds and on every state transition, so an unexpected termination is recoverable on next launch.

---

## Data Models

### Client-side persistence (Drift or Isar)

```dart
class SessionRecord {
  String   id;
  String   phraseRaw;
  String   phraseNormalised;
  DateTime startedAt;
  Duration duration;
  int      voiceCount;
  int      manualCount;
  int      creditsConsumed;
  int      blocksUsed;
  bool     completed;      // false if recovered from crash
}

class PhraseHistoryEntry {
  String   normalised;
  String   raw;
  DateTime lastUsedAt;
  int      useCount;
}
```

### Supabase schema

```sql
create table voice_blocks (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users on delete cascade,
  session_id     uuid not null,
  credits        int  not null,
  granted_at     timestamptz not null default now(),
  expires_at     timestamptz not null,
  reconciled     boolean not null default false,
  streamed_secs  int,
  detections     int
);

create index on voice_blocks (user_id, granted_at desc);
create index on voice_blocks (user_id) where expires_at > now();

alter table voice_blocks enable row level security;
create policy "own blocks readable" on voice_blocks
  for select using (auth.uid() = user_id);
-- no client insert or update policy: writes come from the Edge Function
-- using the service role key only

create table trial_grants (
  rc_app_user_id text primary key,
  credits        int not null,
  granted_at     timestamptz not null default now()
);

create table matcher_config (
  id          int primary key default 1,
  config      jsonb not null,
  updated_at  timestamptz not null default now(),
  constraint singleton check (id = 1)
);

alter table matcher_config enable row level security;
create policy "config readable by all authed" on matcher_config
  for select using (auth.role() = 'authenticated');
```

The `trial_grants` primary key on the RevenueCat app user id makes the one-time trial grant idempotent without any additional logic, which matters because the grant path can be retried.

### Edge Function contract

```
POST /functions/v1/voice-block
Authorization: Bearer <supabase-jwt>
Body: { "session_id": "<uuid>" }

200 { "block_id", "token", "block_seconds", "expires_at", "balance_after" }
401 { "error": "unauthenticated" }
402 { "error": "insufficient_credit", "balance": 2, "required": 5 }
409 { "error": "block_in_flight", "expires_at": "..." }
503 { "error": "provider_unavailable" }
```

```
POST /functions/v1/voice-block/release
Body: { "block_id", "streamed_secs", "detections", "eligible_for_refund" }
200 { "refunded": true|false, "balance": 34 }
```

Refund eligibility is asserted by the client but validated server-side against `granted_at`: a refund is only issued if the release arrives within 30 seconds of grant and reports zero detections (Requirement 3.11). Client assertion alone is not trusted.

---

## Error Handling

| Failure | Detection | Response |
|---|---|---|
| Mic permission denied | `record` permission check | Explain, offer settings deep link, no credit spend (2.2) |
| Offline at session start | Connectivity check | Block start, explain requirement, no credit spend (5.5) |
| Edge Function 402 at start | HTTP status | Show paywall, do not start session |
| Edge Function 402 at renewal | HTTP status | Run current block to completion, then `exhausted` (3.10) |
| Edge Function 409 | HTTP status | Treat stale block as recoverable: wait for expiry or force-release |
| Deepgram grant fails post-debit | Edge Function catch | Refund debit, return 503 (3.6) |
| WebSocket drop mid-block | Socket state | Preserve count, backoff reconnect, tap stays live (5.1, 5.2) |
| Reconnect exhausted (60s) | Backoff timer | `degraded`, stop capture, inform user (5.3) |
| App backgrounded | Lifecycle observer | Pause capture, close socket, preserve count (5.6) |
| Send buffer overflow | Buffer depth check | Drop oldest frames, record in diagnostics |
| Remote config fetch fails | HTTP error | Fall back to cache, then compiled defaults (8.2) |
| Crash mid-session | Checkpoint on next launch | Offer to save recovered session (7.2) |

**Principle applied throughout:** no failure path may destroy the count, and no failure path may spend credits without delivering streaming time.

---

## Security

- The Deepgram master API key exists only in Supabase function secrets. It is never returned to a client under any condition (Requirement 3.12).
- The RevenueCat secret key exists only in function secrets. The client uses the public SDK key, which cannot mutate balances.
- Credit spend happens server-side, keyed on the JWT subject. A client cannot spend on behalf of another user or grant itself credits.
- `voice_blocks` has no client write policy. All writes use the service role key from inside the Edge Function.
- Rate limit `/voice-block` per user id to bound token-grant abuse independently of balance checks.
- The RevenueCat virtual currency API is rate limited to 480 requests per minute across the project, so the Edge Function must handle 429 with backoff and surface it as 503 rather than as a credit error.

---

## Privacy

- Audio is transmitted only during an explicitly started voice session (9.2) and never written to disk (9.4).
- A persistent, visually distinct recording indicator is shown whenever the microphone is live (9.3).
- Deepgram connections set the model improvement program opt-out (9.7).
- Diagnostic transcript logging defaults to off and requires explicit opt-in (9.5). This matters more than usual here: the content being transcribed is devotional or affirmational practice, which many users will regard as private in a way ordinary dictation is not. Consent copy should say plainly what is uploaded and what is not.

---

## Testing Strategy

### Unit tests (the bulk of the value)

`PhraseMatcher` is pure and gets the most coverage:

- Exact match, single detection
- Contraction variance across the same session
- Refractory suppression of duplicate fires from one utterance
- Rapid repetition with no silence between repetitions
- Near-miss below threshold rejected
- Partial phrase spanning two segments
- Token consumption preventing double count
- Adaptive refractory converging on observed median

`BlockClient`: renewal timing, overlap window, 402 handling at start versus at renewal, refund eligibility.

### Fixture-driven integration tests

The critical practice: record real sessions through a debug build, dump the Deepgram transcript stream to JSON, and replay those fixtures through the matcher in CI. This decouples matcher iteration from both network cost and the need to chant into a phone.

Fixture set to capture before tuning anything:

| Fixture | Purpose |
|---|---|
| `normal_100.json` | Baseline recall at conversational pace |
| `rapid_100.json` | Segmentation under minimal inter-rep silence |
| `whispered_100.json` | Low-amplitude recognition degradation |
| `tv_background_100.json` | False positive rate with competing speech |
| `traffic_100.json` | False positive rate with broadband noise |
| `mixed_speech_50.json` | Rejection of non-target speech in the same session |

Each fixture carries a hand-labelled true count. The two metrics that gate release:

- **Recall** = detections / true count. Target ≥ 0.95 on `normal`, ≥ 0.90 on `rapid` and `whispered`.
- **False positives per 10 minutes.** Target ≤ 1 on `tv_background` and `traffic`.

A threshold cannot be tuned by intuition. This fixture set is what makes tuning an evidence-based operation, and it is what tells you early whether cloud STT accuracy is actually worth its cost for this use case.

### Edge Function tests

Deno tests with mocked RevenueCat and Deepgram: happy path, insufficient balance, block in flight, grant failure triggering refund, RevenueCat 429 mapping to 503, JWT rejection.

### Manual verification

Airplane-mode mid-session, backgrounding mid-session, credit exhaustion mid-session, purchase-and-resume, force-quit recovery.

---

## Sequencing Rationale

The task list front-loads a hardcoded-key spike and the fixture corpus. This is deliberate. Steps 1 and 2 of the task list answer the question "is cloud STT accurate enough on real chanting to be worth charging for" at a cost of a few dollars of Deepgram credit and a day of work. Everything after that (credits, paywall, purchase flow, resilience) is only worth building if that answer is yes. Building the billing infrastructure first risks constructing a payment system around a feature that does not work.
