# Implementation Plan

Tasks are ordered so that the accuracy question is answered before any billing infrastructure is built. Task 3 is a hard gate: if recall targets are not met on the fixture corpus, stop and reconsider the approach rather than proceeding to build a paywall around a feature that does not work.

Each task is scoped to be completable in isolation and leaves the app in a working state.

---

## Phase A: Prove the recognition works

- [x] **1. Set up the counting engine abstraction**
  - [x] 1.1 Define `CountingEngine`, `CountEvent`, `EngineStatus`, `PhraseSpec`, `SessionSummary` in `lib/counting/engine.dart`
  - [x] 1.2 Refactor the existing tap counter to implement `CountingEngine` as `TapCountingEngine`, preserving all current behaviour
  - [x] 1.3 Introduce `SessionController` holding the authoritative local count, with `voiceCount` and `manualCount` tracked separately
  - [x] 1.4 Write unit tests confirming tap counting behaviour is unchanged through the new abstraction
  - _Requirements: 6.1, 6.2, 6.3, 6.5_

- [x] **2. Build a throwaway streaming spike**
  - [x] 2.1 Add `record` and `web_socket_channel`; implement `AudioSource` emitting 16 kHz mono PCM16 frames
  - [x] 2.2 Implement `DeepgramSocket` with a hardcoded API key in a debug-only build flavour, connecting with the parameter set from the design document
  - [x] 2.3 Implement `KeepAlive` every 5 s and graceful `CloseStream` with a 2000 ms final-result drain
  - [x] 2.4 Add a debug screen that displays the raw transcript stream live
  - [x] 2.5 Add a debug action that writes the full session's transcript segments to a JSON file on device
  - _Requirements: 2.3, 2.8, 2.9_
  - _Note: the hardcoded key never leaves the debug flavour and is removed entirely in task 8.4_

- [ ] **3. Record the fixture corpus and establish the accuracy baseline**
  - [ ] 3.1 Record six sessions using the task 2 debug build: `normal_100`, `rapid_100`, `whispered_100`, `tv_background_100`, `traffic_100`, `mixed_speech_50`
  - [ ] 3.2 Hand-label the true count for each fixture and commit them under `test/fixtures/transcripts/`
  - [x] 3.3 Build a fixture replay harness that feeds a saved segment stream through a matcher and reports recall and false positives per 10 minutes
  - [ ] 3.4 **Gate:** confirm recall ≥ 0.95 on `normal` is achievable before proceeding. If not, stop and revisit the approach
  - _Requirements: 8.4, 8.5_

- [ ] **4. Implement the phrase matcher**
  - [x] 4.1 Implement the normalisation pipeline: lowercase, punctuation strip, contraction expansion, homophone mapping, whitespace collapse and tokenise
  - [x] 4.2 Implement token-level Levenshtein similarity returning a ratio in [0, 1]
  - [x] 4.3 Implement the sliding window with `windowSlack` sizing and best-score candidate evaluation, preferring the target length and then the earliest occurrence
  - [x] 4.4 Implement token consumption on accepted match so matched tokens cannot contribute again
  - [x] 4.5 Suppress overlapping duplicate audio and retain the optional adaptive waiting period for corpus tuning, defaulting it to zero
  - [x] 4.6 Write the full unit test suite: exact match, contraction variance, refractory suppression, rapid repetition, near-miss rejection, cross-segment phrase, double-count prevention, adaptive convergence
  - [ ] 4.7 Run against all six fixtures and tune `threshold` until recall and false positive targets are met
  - _Requirements: 8.3, 8.4, 8.5, 8.6, 2.7_

- [x] **5. Implement phrase declaration**
  - [x] 5.1 Build the setup screen with phrase text input and a list of the five most recent phrases
  - [x] 5.2 Implement validation: reject fewer than 2 or more than 12 normalised tokens with specific guidance copy
  - [x] 5.3 Implement `PhraseHistoryEntry` local persistence, deduplicated by normalised form
  - [x] 5.4 Derive `keyterms` from the target phrase and pass them into the Deepgram connection parameters
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6_

---

## Phase B: Make it a real session

- [x] **6. Wire the cloud engine into session flow**
  - [x] 6.1 Implement `CloudCountingEngine` composing `AudioSource`, `DeepgramSocket`, and `PhraseMatcher`
  - [x] 6.2 Emit `CountEvent` on each detection; increment the `SessionController` local count
  - [x] 6.3 Add haptic feedback on each increment
  - [x] 6.4 Build the active-session UI: count, elapsed time, engine status, persistent recording indicator
  - [x] 6.5 Keep the tap control visible and functional during voice sessions, feeding the same total with source `manual`
  - [x] 6.6 Implement the decrement gesture with a floor of zero
  - _Requirements: 2.4, 2.5, 2.6, 6.1, 6.2, 6.3, 6.4, 9.3_

- [ ] **7. Implement session persistence and recovery**
  - [ ] 7.1 Define `SessionRecord` and the local database schema
  - [ ] 7.2 Checkpoint the live count to local storage every 10 s and on every state transition
  - [ ] 7.3 On launch, detect an uncompleted checkpoint and offer to save it as a recovered session
  - [ ] 7.4 Build the session history screen, reverse chronological, showing phrase, date and total
  - [ ] 7.5 Build the session summary screen showing the voice and manual breakdown
  - _Requirements: 7.1, 7.2, 7.3, 7.4, 6.4_

- [ ] **8. Build the Edge Function and remove the hardcoded key**
  - [ ] 8.1 Create the `voice_blocks`, `trial_grants`, and `matcher_config` tables with RLS policies as specified
  - [ ] 8.2 Enable Supabase anonymous sign-in and wire it into app startup
  - [ ] 8.3 Implement `POST /voice-block`: JWT verification, in-flight block check (409), RevenueCat balance read, insufficient credit (402), debit, Deepgram token grant, refund-on-grant-failure (503), block row insert
  - [ ] 8.4 Implement `POST /voice-block/release` with server-side validated refund eligibility
  - [ ] 8.5 Delete the hardcoded Deepgram key and the debug flavour that carried it
  - [ ] 8.6 Write Deno tests with mocked providers: happy path, 401, 402, 409, grant-failure refund, RevenueCat 429 mapped to 503
  - [ ] 8.7 Add per-user rate limiting on `/voice-block`
  - _Requirements: 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.11, 3.12_

- [ ] **9. Implement block lifecycle in the client**
  - [ ] 9.1 Implement `BlockClient.acquire` and `.release` against the Edge Function
  - [ ] 9.2 Acquire a block before opening any Deepgram connection at session start
  - [ ] 9.3 Implement renewal at 90% of block duration with overlapping sockets and offset-based deduplication in the matcher
  - [ ] 9.4 Handle 402 at renewal: run the current block to completion, then transition to `exhausted`
  - [ ] 9.5 Call `release` with refund eligibility on session stop
  - [ ] 9.6 Write tests for renewal timing, overlap correctness and each error status
  - _Requirements: 3.1, 3.9, 3.10, 3.11_

---

## Phase C: Monetise

- [ ] **10. Integrate RevenueCat**
  - [ ] 10.1 Configure consumable credit-pack products in App Store Connect and Google Play Console
  - [ ] 10.2 Create the voice-minute virtual currency in RevenueCat and associate the products with grant amounts
  - [ ] 10.3 Add `purchases_flutter`, initialise with the public SDK key, and identify the user against the Supabase user id
  - [ ] 10.4 Implement `EntitlementService`: fetch offerings, present the paywall, execute purchase, invalidate the virtual currency cache and refetch balance
  - [ ] 10.5 Implement the one-time 20-credit trial grant, made idempotent by the `trial_grants` primary key
  - _Requirements: 4.1, 4.2, 4.3, 4.7_

- [ ] **11. Wire credit state into the session UI**
  - [ ] 11.1 Display remaining balance during an active session
  - [ ] 11.2 Implement the low-balance warning at 20% of session-start balance or below 3 credits, whichever is greater
  - [ ] 11.3 On exhaustion, stop audio capture, preserve the count, and present the paywall
  - [ ] 11.4 Implement resume-after-purchase, continuing the same session with its existing count intact
  - _Requirements: 4.4, 4.5, 4.6_

---

## Phase D: Make it survive reality

- [ ] **12. Implement resilience and degraded modes**
  - [ ] 12.1 Implement exponential backoff reconnection from 500 ms capped at 8 s, preserving the count throughout
  - [ ] 12.2 Keep the tap counter enabled during the reconnecting state
  - [ ] 12.3 Transition to `degraded` after 60 s of failed reconnection, stop capture, inform the user
  - [ ] 12.4 Resume within the current block on successful reconnect without acquiring a new one
  - [ ] 12.5 Block session start when offline, with no credit spend
  - [ ] 12.6 Handle backgrounding: pause capture, close socket, preserve count, prompt to resume on return
  - [ ] 12.7 Implement the send-buffer backpressure policy, dropping oldest frames beyond 2 s of buffered audio
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6_

- [ ] **13. Implement permissions and privacy**
  - [x] 13.1 Request microphone permission at session start; on denial, explain and offer a settings deep link with no credit spend
    - `CloudCountingEngine.start()` asks `AudioSource.hasPermission()` before opening the socket and reports `EngineStatus.permissionDenied` on refusal; the counter screen shows `showMicrophoneDeniedDialog` with an Open Settings button backed by `MicrophonePermissionService` (`permission_handler`).
  - [x] 13.2 Add the first-run disclosure that audio is sent to a third-party recognition provider during voice sessions
    - `showVoiceDisclosureSheet` gates the mic button until accepted; persisted as `AppSettings.voiceDisclosureSeen` (Hive field 8, default false).
  - [x] 13.3 Set the Deepgram model improvement program opt-out on every connection
    - `DeepgramSocket.buildUri` always appends `mip_opt_out=true`.
  - [x] 13.4 Verify by inspection and test that no audio is ever written to disk
    - `test/services/counting/no_audio_to_disk_test.dart` asserts nothing under `lib/core/services/counting/` touches the file system, and that the debug screen's only write is the transcript JSON export.
  - [ ] 13.5 Implement the opt-in diagnostics toggle, defaulted off, uploading transcript segments and match decisions only
    - Deferred: there is no backend to upload to until task 8 (Edge Function) lands. Nothing leaves the device today, which satisfies the default-off half of 9.5.
  - _Requirements: 2.1, 2.2, 9.1, 9.2, 9.4, 9.5, 9.6, 9.7_

- [ ] **14. Implement remote matcher configuration**
  - [ ] 14.1 Fetch `MatcherConfig` from `matcher_config` on app start
  - [ ] 14.2 Cache the last successful config locally; fall back to cache then to compiled defaults on fetch failure
  - [ ] 14.3 Confirm a config change takes effect on next session start without an app release
  - _Requirements: 8.1, 8.2_

- [ ] **15. Implement observability and cost controls**
  - [ ] 15.1 Log user id, block id, credits and timestamp on every grant
  - [ ] 15.2 Report session id, blocks used, streamed seconds and detection count on session end, best-effort
  - [ ] 15.3 Mark blocks unreconciled rather than erroring when no report arrives
  - [ ] 15.4 Configure the hard spend limit on the Deepgram project
  - [ ] 15.5 Write the reconciliation query comparing credits debited against Deepgram reported usage for a period
  - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5_

- [ ] **16. End-to-end verification**
  - [ ] 16.1 Manual pass: airplane mode mid-session, backgrounding mid-session, exhaustion mid-session, purchase-and-resume, force-quit recovery
  - [ ] 16.2 Re-run the full fixture suite and confirm recall and false positive targets still hold after all integration work
  - [ ] 16.3 Verify no code path can return the Deepgram master key to a client
  - [ ] 16.4 Verify credits are never spent on any path that fails to deliver streaming time
  - _Requirements: 3.12, 5.5, 5.6, 7.2, 4.6_
