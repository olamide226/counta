# Design Document

## Overview

Voice phrase counting adds cloud streaming speech recognition to the existing tap counter. The design has one governing constraint: **accuracy is the reason for choosing cloud STT, and per-minute cost is the price of that choice.** Every architectural decision below follows from bounding that cost without operating infrastructure.

The design deliberately avoids a server-side audio relay. Deepgram supports short-lived tokens for direct client connections, and RevenueCat provides virtual currency balance management, so the entire server-side footprint is one Supabase Edge Function and a handful of small tables. The Flutter client owns audio capture, the Deepgram WebSocket, and phrase matching.

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
│  AttestationSource (DeviceCheck, Integrity) │
└────┬──────────────────────┬─────────────────┘
     │ HTTPS                │ WSS (audio out, transcripts in)
     │                      │
     ▼                      ▼
┌────────────────────────┐   ┌──────────────┐
│ Supabase               │   │  Deepgram    │
│  Edge Function         │   │  /v1/listen  │
│  /voice-block          │   └──────────────┘
│                        │           ▲
│  Postgres, schema      │           │ mints token
│  "counta":             │           │
│    voice_blocks        │           │
│    matcher_config      │───────────┘
│    trial_grants        │
│    vouchers            │
│    voucher_redemptions │
│    voucher_attempts    │
└──┬─────────────────┬───┘
   │                 │ trial only: query and set the device bit,
   │                 │ verify the integrity verdict
   │                 ▼
   │        ┌────────────────────────┐
   │        │ Apple DeviceCheck      │
   │        │ Google Play Integrity  │
   │        └────────────────────────┘
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
     check live block for user             → 409 unless the session_id matches
     read RevenueCat balance               → 402 if < BLOCK_CREDITS
     spend BLOCK_CREDITS on RevenueCat
     POST Deepgram /v1/auth/grant (ttl=30) → refund + 503 on failure
     insert counta.voice_blocks row
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
| `counta.voice_blocks`, `counta.matcher_config`, `counta.trial_grants`, `counta.vouchers`, `counta.voucher_redemptions`, `counta.voucher_attempts` | Supabase Postgres, `counta` schema | RLS on all six; schema must be in the project's exposed-schemas list |
| Secrets | Supabase function secrets | `DEEPGRAM_API_KEY`, `REVENUECAT_SECRET_KEY`, `REVENUECAT_PROJECT_ID`, plus the trial-gate credentials in "Trial eligibility and vouchers" |
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
  final double refractoryMultiplier; // default 0; optional corpus tuning
  final int    refractoryFloorMs;    // default 0; optional corpus tuning
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

  candidates := every slice whose tokenSimilarity meets the threshold
  best := highest score, then closest target length, then earliest occurrence

  if best overlaps the last accepted audio span:
      consume best as a duplicate
  else:
      emit Detection(best.score, best.audioOffset)
      consume best so it cannot match again
      record utterance duration for optional tuning statistics
```

**Normalisation pipeline**, applied identically to target and to incoming text:

1. Lowercase
2. Convert curly apostrophes to straight apostrophes
3. Expand contractions from config map (`i'm` to `i am`, `don't` to `do not`)
4. Strip punctuation and non-word characters
5. Apply homophone map from config
6. Collapse whitespace, split on whitespace

This is why `"I'm rich in wisdom"`, `"im rich in wisdom"`, and `"i am rich in wisdom"` all score as the same phrase. Deepgram will produce all three across a single session.

**Similarity** is token-level Levenshtein distance normalised to a ratio in [0, 1], not exact string equality. Exact matching fails on the first dropped article.

**Duplicate protection uses audio overlap by default.** A candidate whose audio begins before the previous accepted phrase ends is discarded and its tokens are consumed. Non-overlapping phrases are accepted even when spoken rapidly. The matcher retains optional `refractoryFloorMs` and `refractoryMultiplier` controls for future corpus experiments, but both default to zero because the recorded fixtures showed that a mandatory pause suppressed real repetitions.

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

The tables live in a dedicated `counta` schema rather than in `public`.
The Supabase project is shared staging: other products already occupy a schema
each (`mcpl`, `mcp_oauth`) and `public` belongs to an unrelated website, so one
schema per product is both the house convention and the only way this feature's
migration can be applied without reaching into someone else's namespace. The
migration is additive and confined to `counta`; the sole reference outside it is
the foreign key to `auth.users`.

Because the Data API's auto-expose default covers `public` only, grants are
explicit, and PostgREST serves `counta` only once it is added to the project's
exposed-schemas list (a manual dashboard step — see `supabase/README.md`).

```sql
create schema if not exists counta;
grant usage on schema counta to anon, authenticated, service_role;

create table counta.voice_blocks (
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

create index on counta.voice_blocks (user_id, granted_at desc);
create unique index on counta.voice_blocks (user_id) where not reconciled;

alter table counta.voice_blocks enable row level security;
create policy "own blocks readable" on counta.voice_blocks
  for select using (auth.uid() = user_id);
-- no client insert or update policy: writes come from the Edge Function
-- using the service role key only, and the grants match
grant select on counta.voice_blocks to authenticated;
grant select, insert, update, delete on counta.voice_blocks to service_role;

create table counta.trial_grants (
  user_id     uuid primary key references auth.users on delete cascade,
  platform    text not null check (platform in ('ios', 'android')),
  gate        text not null check (gate in ('devicecheck', 'play_integrity')),
  credits     int  not null check (credits > 0),
  granted_at  timestamptz not null default now()
);

-- no client grant and no policy at all: service_role writes it, and the
-- primary key makes the one-time grant idempotent
grant select, insert, update, delete on counta.trial_grants to service_role;

create table counta.vouchers (
  id               uuid primary key default gen_random_uuid(),
  code             text not null,
  credits          int  not null check (credits > 0),
  max_redemptions  int  not null check (max_redemptions > 0),
  redeemed_count   int  not null default 0 check (redeemed_count >= 0),
  expires_at       timestamptz,          -- null: never expires
  enabled          boolean not null default true,
  note             text,
  created_at       timestamptz not null default now(),
  constraint vouchers_within_cap check (redeemed_count <= max_redemptions)
);

create unique index on counta.vouchers (upper(code));

create table counta.voucher_redemptions (
  id          uuid primary key default gen_random_uuid(),
  voucher_id  uuid not null references counta.vouchers on delete restrict,
  user_id     uuid not null references auth.users on delete cascade,
  credits     int  not null check (credits > 0),
  redeemed_at timestamptz not null default now()
);

create unique index on counta.voucher_redemptions (voucher_id, user_id);

create table counta.voucher_attempts (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users on delete cascade,
  attempted_at timestamptz not null default now()
);

create index on counta.voucher_attempts (user_id, attempted_at desc);

-- the three voucher tables get no policy and no client grant: the codes are
-- the secret, and any select policy would let an anonymous session enumerate
-- every live campaign
alter table counta.vouchers enable row level security;
alter table counta.voucher_redemptions enable row level security;
alter table counta.voucher_attempts enable row level security;

create table counta.matcher_config (
  id          int primary key default 1,
  config      jsonb not null,
  updated_at  timestamptz not null default now(),
  constraint singleton check (id = 1)
);

alter table counta.matcher_config enable row level security;
create policy "config readable by all authed" on counta.matcher_config
  for select using (auth.role() = 'authenticated');
grant select on counta.matcher_config to authenticated;
grant select, insert, update, delete on counta.matcher_config to service_role;
```

The live-block index is a partial **unique** index rather than the
`where expires_at > now()` this section once sketched: `now()` is not
`IMMUTABLE`, so Postgres rejects that predicate. `not reconciled` is immutable,
is the set that must stay unique (Requirement 3.8), and serves the in-flight
lookup as well.

`trial_grants` was keyed on the RevenueCat app user id until the trial became device-gated. It is now keyed on the Supabase user id, which serves the same purpose — a retried grant collides with the primary key rather than paying out twice — while the question of whether this *device* has already taken the trial is answered by the platform gate described in "Trial eligibility and vouchers" below, not by any identity the app can mint for itself.

Two voucher invariants are database constraints rather than handler logic, for the reason the live-block index is: the handler's read-then-write is passable by two concurrent requests, and what is being protected is a credit grant.

- `voucher_redemptions (voucher_id, user_id)` unique is the one-redemption-per-user rule (Requirement 12.4). It doubles as the "has this user already redeemed this code?" lookup.
- `vouchers_within_cap` makes it impossible to record more redemptions than the campaign allows. The handler claims a slot with `update counta.vouchers set redeemed_count = redeemed_count + 1 where id = $1 and redeemed_count < max_redemptions returning *`, which takes the row lock and refuses cleanly when the campaign is full; the check constraint is the backstop for a writer that forgets the predicate.

Codes fold to upper case for both lookup and uniqueness, because they are typed by hand off a card or an email. `expires_at` is nullable and null means "never expires".

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
200 { "refunded": true, "balance": 34 }
200 { "refunded": false }
400 { "error": "invalid_detections" }
```

```
POST /functions/v1/voice-block/token
Authorization: Bearer <supabase-jwt>
Body: { "block_id": "<uuid>" }

200 { "token": "<deepgram jwt>", "expires_in": 30 }
400 { "error": "invalid_request" }
401 { "error": "unauthenticated" }
404 { "error": "block_not_found" }
429 { "error": "rate_limited" }
503 { "error": "provider_unavailable" }
```

`/token` mints a fresh streaming credential for a block the caller already holds, and **never debits**. It exists because the 30-second token TTL governs connection establishment only: a socket already open stays authorised for its lifetime, but a socket that *drops* 200 seconds into a 300-second block has no credential left to open a new one, so only the first 10% of a block could survive a network blip. Asking `/voice-block` for another grant is worse than useless — a grant carrying the live block's `session_id` is read as the renewal of Requirement 3.9 and would debit a whole block per dropped socket. The block was paid for when it was granted; a user must not be charged for a bad network.

Ownership, the reconciled flag and the expiry are all checked server-side against `counta.voice_blocks`, and unknown, not-the-caller's, already-released and expired blocks are deliberately one answer: a block belonging to another user must be indistinguishable from one that does not exist, or the endpoint becomes an oracle for live block ids. The route is rate limited per user (`TOKEN_MINT_MAX` per `TOKEN_MINT_WINDOW_MINUTES`) because a mint is cheap but not free, and an unmetered route that hands out provider credentials is exactly the thing not to leave lying around. That budget is held in the worker's memory rather than in Postgres — a token mint writes no row, so metering it with a database round trip would cost more than the thing being metered; the trade is a per-worker rather than a per-user bound, on a route that already requires a live block.

One block is live per user at a time, and renewal is identified by `session_id` rather than inferred from a clock. A grant whose `session_id` matches the caller's live block is the 90% renewal of Requirement 3.9: it is granted and the block it replaces is marked reconciled in the same request, so the invariant still holds. A grant carrying any other `session_id` is a 409 no matter how close the live block is to expiry — treating a nearly expired block as "not live" would hand a second, unrelated session a concurrent block for the length of that window, which is what Requirement 3.8 exists to prevent. A partial unique index on `counta.voice_blocks (user_id) where not reconciled` enforces this in the database as well, so two concurrent requests cannot both pass the check.

Refund eligibility is asserted by the client but validated server-side against `granted_at`: a refund is only issued if the release arrives within 30 seconds of grant and reports zero detections (Requirement 3.11). Client assertion alone is not trusted.

```
POST /functions/v1/voice-block/trial
Authorization: Bearer <supabase-jwt>
Body: { "platform": "ios",     "device_token":    "<base64 DCDevice token>" }
Body: { "platform": "android", "integrity_token": "<Play Integrity token>" }

200 { "granted": true,  "credits": 20, "balance": 20 }
200 { "granted": false, "reason": "already_claimed" }              // the device
200 { "granted": false, "reason": "already_claimed", "credits": 20 } // this user
400 { "error": "invalid_attestation" }
401 { "error": "unauthenticated" }
409 { "error": "platform_unsupported" }
503 { "error": "attestation_unavailable" }
503 { "error": "provider_unavailable" }
```

The two 503s are different failures and the client can treat them alike but an
operator cannot. `attestation_unavailable` is Apple or Google being
unreachable, answering `UNEVALUATED`, or rejecting our own credentials — the
device is undecided and the trial stays unclaimed (Requirement 11.9).
`provider_unavailable` is the ledger call failing after the device passed.

The `credits` field distinguishes the two "already claimed" answers without the
client having to care: with it, this *caller* has a `counta.trial_grants` row;
without it, this *device* has the DeviceCheck bit set under some other,
earlier, anonymous user.

```
POST /functions/v1/voice-block/redeem
Authorization: Bearer <supabase-jwt>
Body: { "code": "SPRING24" }

200 { "redeemed": true,  "credits": 50, "balance": 71 }
200 { "redeemed": false, "reason": "already_redeemed", "credits": 50, "balance": 71 }
400 { "error": "invalid_request" }
401 { "error": "unauthenticated" }
404 { "error": "voucher_invalid" }
409 { "error": "voucher_expired" }
409 { "error": "voucher_exhausted" }
429 { "error": "too_many_attempts", "retry_after_seconds": 900 }
503 { "error": "provider_unavailable" }
```

Both new endpoints sit behind the same JWT verification as the block endpoints and grant through the same `BalanceProvider` seam, so there is exactly one code path that moves credits and exactly one place to audit.

"Already claimed" and "already redeemed" are 200s carrying a negative result rather than errors. They are the expected answer to an ordinary question — every reinstall asks the trial endpoint, and a user who taps Redeem twice asks the second one — and in both cases the client does what it would have done anyway: show the current balance. Reserving the 4xx codes for genuinely malformed or refused requests keeps the client's error handling about errors.

`voucher_invalid` deliberately covers both "no such code" and "disabled", with no way to tell them apart (Requirement 12.6): distinguishing them turns the endpoint into an oracle for discovering live codes. Expiry and exhaustion do get their own answers (12.7), because those reach a user holding a real code, and telling that user the code is fake is worse than the little the distinction leaks. Failed attempts are counted per user in `counta.voucher_attempts` and rate limited, which is what actually bounds guessing.

Ordering inside a trial grant matters as much as it does inside a block grant:

```
verify JWT
platform is ios or android, and has a configured gate  -> 409 platform_unsupported
counta.trial_grants row for this user?                 -> 200 granted:false
DeviceAttestor.check(payload)                          -> 400 rejected,
                                                          503 indeterminate,
                                                          200 granted:false if
                                                          the bit is set
BalanceProvider.grant(user, "trial:<user>", credits)   -> 503 on failure
insert counta.trial_grants                             -> PK collision means a
                                                          concurrent request won
DeviceAttestation.claim()  (iOS: set the bit)          -> logged, never thrown
```

The credits move before either record is written, and the ledger call is keyed
on the user id. That key is what makes every step after it recoverable: a
retry re-issues the *same* grant, which the ledger applies once, so a failure
anywhere below leaves the caller with credits, no grant row and no bit — a
state the next attempt walks straight through. Writing the row first would
work too, but then every later "already claimed" answer would have to re-issue
the grant to stay self-healing, and that spends a RevenueCat write on every
reinstall for no gain.

The bit is set last, and never allowed to fail the request. It is what makes
the device ineligible for ever (Requirement 11.3), so setting it before the
credits landed would burn a device's only claim on a request that then failed;
refusing a grant the user has already been given because the bit write failed
would cost them the feature. Losing a bit costs the operator one extra trial,
which is the cheaper of the two mistakes — so the failure is logged loudly and
the grant stands.

Ordering inside a redemption matters as much as it does inside a block grant:

```
verify JWT
rate-limit check on counta.voucher_attempts         -> 429
look up voucher by upper(code)                      -> 404 / 409 expired,
                                                       record an attempt
claim a slot: redeemed_count + 1 under the cap      -> 409 voucher_exhausted
insert counta.voucher_redemptions                   -> unique violation means
                                                       already redeemed: release
                                                       the slot, re-issue the
                                                       keyed grant, report 200
BalanceProvider grant(user, redemption_id, credits) -> 503 on failure
```

The slot claim and the redemption row are two writes that must not come apart, so they belong in one transaction — the simplest form is a `counta.redeem_voucher(...)` SQL function called over RPC, added alongside the endpoint in task 10, which also keeps the whole decision one round trip. If they are ever issued as separate statements, claim the slot **first**: a leaked slot means a campaign gives out one fewer redemption than it advertised, while a redemption row with no slot behind it means the cap can be exceeded. When the two failure directions are under-granting and over-granting credit, take the first.

The redemption row is written before any credit moves, and the ledger call is keyed on the redemption id exactly as a block debit is keyed on the block id. A retry therefore re-issues the *same* keyed grant rather than a second one: a redemption whose ledger call died mid-flight completes on the next attempt, and one that already succeeded cannot pay out twice. That is what makes the endpoint idempotent and unfarmable by retry (Requirements 12.5, 12.8). A slot claimed for a grant that then fails permanently is left consumed; the remedy is for the operator to raise the cap, which is better than releasing slots automatically and giving a retry loop something to chew on.

---

## Trial eligibility and vouchers

### Why the trial needs a device, not an account

Requirement 4.3 used to key the 20-credit trial on the RevenueCat app user id. Both that id and the Supabase anonymous user are minted on first launch and thrown away with the app, so the price of a second trial was a reinstall and the price of a thousand was a script. A trial is worth roughly 20 minutes of Deepgram time: small per user, unbounded in aggregate — exactly the shape of thing that has to be gated on something the app cannot re-mint.

The only such thing available to a mobile app, short of collecting an identifier the stores forbid, is a platform attestation. The two platforms offer very different amounts of it.

### iOS: DeviceCheck

Apple's DeviceCheck stores **two bits per device, per developer team, on Apple's servers**. The bits survive app deletion, reinstall, device reset, and a change of the Apple Account signed in on the device, and Apple documents limiting a free trial to once per device as their intended use for them. The app calls `DCDevice.current.generateToken()` and sends the token up; everything else happens server-side.

```
client                     Edge Function                    Apple
DCDevice token  --------> sign ES256 JWT (team key)
                          POST /v1/query_two_bits    ---->
                                                     <----  bit0, bit1, last_update_time
                          bit0 set?  --------------------->  200 { granted: false }
                          BalanceProvider grant(...)
                          insert counta.trial_grants
                          POST /v1/update_two_bits   ---->   bit0 := 1
                200 { granted: true, credits: 20 }
```

The bit is set *after* the credits are granted and before the response, so a crash between the two costs the operator one extra trial rather than silently burning a device's only claim. The grant row goes in first for the same reason in miniature: if the bit write is the thing that fails, this caller at least cannot ask again.

A device Apple has never seen has no bit state, and Apple answers that with a **200** whose body is not the bit document. Apple's own docs give a "descriptive string" column rather than a wire contract, and the strings observed in production differ from it, so the implementation matches on the *absence* of `bit0`/`bit1` and reads that as unclaimed. Nothing branches on Apple's body text; the status code decides and the body only reaches the logs.

The two bits are individually optional on `update_two_bits`, and Apple does not document what omitting one does to its stored value. Both are therefore always sent, with the sibling app's bit written back exactly as the query returned it — guessing wrong would silently clobber another product's flag.

#### DeviceCheck bit allocation

The two bits belong to the **Apple developer team**, not to an app. Every app the team ships queries and writes the same two bits for a given device, so an app that picks a bit at random will eventually collide with a sibling and silently deny someone else's trial. The allocation is therefore recorded here, and must be checked before any other app on this team uses DeviceCheck (Requirement 11.4).

| Bit | Owner | Meaning when set |
|---|---|---|
| `bit0` | Counta | This device has claimed the Counta voice trial |
| `bit1` | unallocated | Claim it in this table, in the same commit that starts using it |

`DEVICECHECK_TRIAL_BIT` carries the same number in configuration so the code and the doc cannot drift silently, but this table is the record.

### Android: Play Integrity, and what it does not give

Android has no DeviceCheck equivalent. Play Integrity attests that a genuine, unmodified build of the app is running on a genuine Android device with a licensed Play install — and that is all. **It offers no per-device storage, so there is nowhere to record that this device has taken the trial.** The Android gate is therefore:

1. a Play Integrity verdict, verified server-side, requiring device integrity, an app recognised by Play, and a licensed install, and
2. a row in `counta.trial_grants` keyed on the Supabase user id.

Concretely, the Edge Function mints a Google access token with the service account's JWT-bearer grant, calls `POST https://playintegrity.googleapis.com/v1/{package}:decodeIntegrityToken`, and accepts the verdict only when it names this package, was minted within the last ten minutes, and reports `appRecognitionVerdict: PLAY_RECOGNIZED`, `MEETS_DEVICE_INTEGRITY` among the device verdicts, and `appLicensingVerdict: LICENSED`. `MEETS_BASIC_INTEGRITY` alone is not enough, and an empty device-verdict array is Google's positive statement that the device shows signs of attack.

A verdict Google marks `UNEVALUATED` is not a refusal — it is not an answer. Reading it as "no" would permanently deny a legitimate device that happened to ask during a Play Store outage, so it becomes the 503 of Requirement 11.9 and the trial stays unclaimed. The freshness window is there because a leaked genuine token, replayed across many fresh anonymous accounts, would otherwise buy a trial each for the price of one real device.

That stops emulators, rooted-device farms, repackaged builds and scripted signups, which is most of the volume abuse. It does **not** stop a person with a real phone deleting the app, signing in anonymously again, and taking a second trial. **The Android trial gate is weaker than the iOS one, and no amount of design fixes that**; saying so plainly here is better than an implementation that reads as equivalent.

The obvious way to close the gap is a device fingerprint — hardware ids, an advertising id, a hash of build properties. Both stores prohibit it for this purpose, so it appears nowhere in this design (Requirement 11.7). If Android farming turns out to be material in practice, the honest levers are a smaller Android trial, a trial that requires a signed-in Google account rather than an anonymous one, or no Android trial at all. Each is a product decision, not a technical trick.

Platforms with no attestation at all (macOS, Windows, Linux, web) are not offered the trial (Requirement 11.10); the endpoint answers `platform_unsupported`.

### Credentials the operator must obtain

| Setting | Where it comes from |
|---|---|
| `APPLE_TEAM_ID` | Apple Developer account, Membership details |
| `APPLE_DEVICECHECK_KEY_ID` | Certificates, Identifiers & Profiles -> Keys -> a key with DeviceCheck enabled |
| `APPLE_DEVICECHECK_PRIVATE_KEY` | The `.p8` contents for that key, downloadable exactly once |
| `APPLE_DEVICECHECK_HOST` | `api.devicecheck.apple.com`, or `api.development.devicecheck.apple.com` for builds signed with a development profile |
| `DEVICECHECK_TRIAL_BIT` | `0`, per the allocation table above |
| `PLAY_INTEGRITY_PACKAGE_NAME` | The Android application id |
| `PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON` | Google Cloud service account with the Play Integrity API enabled, linked to the Play Console app |
| `TRIAL_CREDITS` | Product decision; 20, per Requirement 4.3 |
| `VOUCHER_ATTEMPT_MAX`, `VOUCHER_ATTEMPT_WINDOW_MINUTES` | Guess-rate budget; 10 per hour to start |

DeviceCheck's sandbox and production hosts hold **separate** bit stores. A device that claimed the trial against the development host has not claimed it against production — which is what makes testing possible at all, and also means a build pointed at the wrong host reports every device as unclaimed.

### Vouchers

A voucher is one code, many users, capped: `max_redemptions` bounds the campaign and the unique index on `(voucher_id, user_id)` bounds the individual. Codes are created by the operator with the service role — inserted by hand or by a small script — and the app has no write path to them at all (Requirement 12.10). There is no self-serve code generation and no admin UI in this iteration; a campaign is a few rows of SQL.

Redemption reuses the credit machinery rather than paralleling it: the same JWT verification, the same `BalanceProvider`, the same keyed-grant idempotency, the same log fields as a block grant. The only genuinely new mechanism is the attempt counter, and it exists because a redeem endpoint that answers unbounded guesses is a code-guessing oracle however carefully its answers are worded.

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
| WebSocket stays open but stops responding | No server message for 20s while audio flows | Show reconnecting and replace the socket without restarting healthy capture (5.1, 5.7) |
| Reconnect exhausted (60s) | Backoff timer | `degraded`, stop capture, inform user (5.3) |
| App backgrounded | Lifecycle observer | Pause capture, close socket, preserve count (5.6) |
| Send buffer overflow | Buffer depth check | Drop oldest frames, record in diagnostics |
| Remote config fetch fails | HTTP error | Fall back to cache, then compiled defaults (8.2) |
| Crash mid-session | Checkpoint on next launch | Offer to save recovered session (7.2) |
| Trial already claimed on this device | DeviceCheck bit set, or a `trial_grants` row | 200 `granted: false`; show the paywall, no error copy (11.2, 11.8) |
| DeviceCheck or Play Integrity unreachable | Attestation call fails or is indeterminate | 503, no credits; the client may retry, and the trial stays unclaimed (11.9) |
| Attestation rejected as unverifiable | Apple/Google reject the token | 400, no credits, no `trial_grants` row; do not retry the same token |
| Trial asked for on an unsupported platform | `platform` not `ios` or `android` | 409 `platform_unsupported`; the trial is not offered there at all (11.10) |
| Voucher unknown or disabled | Lookup on `upper(code)` | 404 `voucher_invalid`, indistinguishable between the two, attempt recorded (12.6) |
| Voucher expired or fully redeemed | `expires_at`, `redeemed_count` | 409 with the specific reason, attempt recorded (12.7) |
| Voucher already redeemed by this user | Unique violation on `(voucher_id, user_id)` | 200 `redeemed: false`; re-issue the keyed grant, never a second one (12.5) |
| Too many failed redemptions | Count in `counta.voucher_attempts` | 429 with `retry_after_seconds`; bounds code guessing (12.8) |
| Ledger call fails after the redemption row exists | `BalanceProvider` error | 503; the retry finds the row and re-issues the same keyed grant (12.5) |

**Principle applied throughout:** no failure path may destroy the count, and no failure path may spend credits without delivering streaming time.

---

## Security

- The Deepgram master API key exists only in Supabase function secrets. It is never returned to a client under any condition (Requirement 3.12).
- The RevenueCat secret key exists only in function secrets. The client uses the public SDK key, which cannot mutate balances.
- Credit spend happens server-side, keyed on the JWT subject. A client cannot spend on behalf of another user or grant itself credits.
- `counta.voice_blocks` has no client write policy. All writes use the service role key from inside the Edge Function.
- Rate limit `/voice-block` per user id to bound token-grant abuse independently of balance checks.
- **No client claim about free credit is ever trusted** (Requirement 4.8). A client that says "I have not had the trial" is asserting something it cannot know and has every incentive to get wrong: the app it runs in is reinstallable, its Supabase user is anonymous and re-mintable, and its RevenueCat id comes with it. Trial eligibility is decided from an attestation the app cannot forge (DeviceCheck bits held by Apple, a Play Integrity verdict signed by Google) plus the Edge Function's own records, and the grant is applied server-side.
- The same holds for vouchers. A code is validated server-side against `counta.vouchers`, which no client role can read, and the two rules that bound the payout — one redemption per user, and the campaign cap — are database constraints rather than handler logic, so neither concurrency nor a bug in a code path can exceed them.
- `counta.vouchers`, `counta.voucher_redemptions`, `counta.voucher_attempts` and `counta.trial_grants` have RLS on, no policy, and no grant to `anon` or `authenticated`. The codes are the secret; a select policy for `authenticated`, however narrow, would let any anonymous session enumerate every live campaign.
- The DeviceCheck private key and the Play Integrity service account credentials live only in function secrets, alongside the Deepgram and RevenueCat keys. A device token is worthless without them, which is why the check has to be server-side rather than in the app.
- No device fingerprint, advertising identifier or hardware id is collected for gating (Requirement 11.7). The consequence — a weaker Android trial gate — is accepted and documented rather than worked around.
- The RevenueCat virtual currency API is rate limited to 480 requests per minute across the project, so the Edge Function must handle 429 with backoff and surface it as 503 rather than as a credit error.

---

## Privacy

- Audio is transmitted only during an explicitly started voice session (9.2) and never written to disk (9.4).
- A persistent, visually distinct recording indicator is shown whenever the microphone is live (9.3).
- Deepgram connections set the model improvement program opt-out (9.7).
- Trial gating collects no device fingerprint, advertising identifier or hardware id (Requirement 11.7). What leaves the device is an opaque, single-use attestation token that only Apple or Google can interpret; what is stored is a bit at Apple, or a row keyed on the Supabase user id.
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

The trial and redeem endpoints get the same treatment, with the attestation providers faked: a DeviceCheck bit already set, an indeterminate verdict mapped to 503, an unsupported platform, a retried grant paying out exactly once, an unknown code and a disabled code producing byte-identical answers, expiry and cap refusals, a second redemption by the same user, and a ledger failure that completes rather than doubles on retry.

### Manual verification

Airplane-mode mid-session, backgrounding mid-session, credit exhaustion mid-session, purchase-and-resume, force-quit recovery.

---

## Sequencing Rationale

The task list front-loads a hardcoded-key spike and the fixture corpus. This is deliberate. Steps 1 and 2 of the task list answer the question "is cloud STT accurate enough on real chanting to be worth charging for" at a cost of a few dollars of Deepgram credit and a day of work. Everything after that (credits, paywall, purchase flow, resilience) is only worth building if that answer is yes. Building the billing infrastructure first risks constructing a payment system around a feature that does not work.
