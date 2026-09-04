# Requirements Document

## Introduction

The counter app currently supports tap-based tallying: the user taps a button and watches a running total. This feature adds **voice phrase counting**, allowing a user to nominate a phrase or mantra (for example "I'm rich in wisdom") and have the app count each spoken repetition automatically for the duration of a session.

Recognition uses cloud streaming speech-to-text (Deepgram Nova-3) for accuracy. Because streaming STT carries a per-minute cost, the feature is gated behind a credit paywall denominated in **voice minutes**, sold as consumable in-app purchases and tracked by RevenueCat.

The system has no backend today. This feature introduces exactly one server-side component: a Supabase Edge Function that validates entitlement, debits credits, and mints short-lived Deepgram tokens. The Flutter client streams audio directly to Deepgram and performs phrase matching locally.

### Scope

**In scope for this iteration**
- Single-phrase counting per session, phrase declared before the session starts
- Foreground-only sessions (screen may dim, app must remain foreground)
- English language recognition
- Block-based credit consumption with in-app purchase of credit packs
- Coexistence with the existing tap counter within a single session total
- Local session persistence and history

**Out of scope for this iteration**
- Background or screen-off counting
- Automatic detection of which phrase to count without user declaration
- Multi-phrase or multi-language sessions
- Server-side audio relay and server-side matching
- Cross-device sync of session history

### Glossary

| Term | Meaning |
|---|---|
| **Block** | A pre-paid unit of streaming time (default 300 seconds) granted by the Edge Function |
| **Credit** | One voice minute. The unit of the RevenueCat virtual currency |
| **Detection** | A single accepted match of the target phrase in the transcript stream |
| **Refractory period** | Time after a detection during which further detections are suppressed |
| **Segment** | A finalised transcript fragment returned by Deepgram with `is_final: true` |
| **Session** | One continuous counting activity, from Start to Stop, spanning one or more blocks |

---

## Requirements

### Requirement 1: Phrase declaration

**User Story:** As a practitioner, I want to tell the app which phrase I intend to repeat, so that it counts only that phrase and ignores everything else I say.

#### Acceptance Criteria

1.1. WHEN the user opens the voice counting setup screen THEN the system SHALL present a text input for the target phrase and a list of the user's five most recently used phrases.
1.2. WHEN the user submits a phrase THEN the system SHALL normalise it and store it as the session's target phrase.
1.3. IF the submitted phrase normalises to fewer than 2 tokens THEN the system SHALL reject it and display guidance that short phrases produce unreliable counts.
1.4. IF the submitted phrase normalises to more than 12 tokens THEN the system SHALL reject it and display guidance that long phrases exceed the matching window.
1.5. WHEN a phrase is accepted THEN the system SHALL persist it to the local phrase history, deduplicated by normalised form.
1.6. WHEN a session starts THEN the system SHALL supply the target phrase tokens to Deepgram as `keyterm` parameters to bias recognition.
1.7. WHEN voice capture is paused and resumed within the same counting session THEN the system SHALL keep the most recently selected phrase and prefill it on the resume screen.

### Requirement 2: Voice counting session

**User Story:** As a practitioner, I want the app to increment a counter each time I say my phrase, so that I can keep my practice without touching the screen.

#### Acceptance Criteria

2.1. WHEN the user starts a voice session THEN the system SHALL request microphone permission if not already granted.
2.2. IF microphone permission is denied THEN the system SHALL display an explanation and offer to open system settings, and SHALL NOT consume any credits.
2.3. WHEN a voice session is active THEN the system SHALL capture audio at 16 kHz, mono, 16-bit PCM and stream it to Deepgram over a WebSocket.
2.4. WHEN the matcher accepts a detection THEN the system SHALL increment the session count within 1500 ms of the utterance ending.
2.5. WHEN the session count increments THEN the system SHALL fire a short haptic pulse.
2.6. WHILE a voice session is active THE system SHALL display the current count, the elapsed session time, and the remaining credit balance.
2.7. WHEN a detection occurs THEN the system SHALL suppress a later detection whose matched audio overlaps the already-counted audio. An additional adaptive waiting period MAY be enabled through matcher configuration, but SHALL default to zero so rapid non-overlapping repetitions are counted.
2.8. WHEN no audio is transmitted for 5 seconds THEN the system SHALL send a Deepgram `KeepAlive` message to prevent idle disconnection.
2.9. WHEN the user stops the session THEN the system SHALL send `CloseStream`, wait up to 2000 ms for final results, apply any late detections, and then close the socket.

### Requirement 3: Block-based credit consumption

**User Story:** As the app operator, I want streaming time to be paid for in advance in small blocks, so that my speech-to-text spend can never exceed what a user has purchased.

#### Acceptance Criteria

3.1. WHEN a voice session starts THEN the client SHALL request a block from the Edge Function before opening any Deepgram connection.
3.2. WHEN the Edge Function receives a block request THEN it SHALL verify the Supabase JWT and reject unauthenticated requests with HTTP 401.
3.3. WHEN a block request is authenticated THEN the Edge Function SHALL read the caller's credit balance from the RevenueCat Developer API.
3.4. IF the caller's balance is below the block cost THEN the Edge Function SHALL return HTTP 402 with the current balance and SHALL NOT mint a Deepgram token.
3.5. WHEN the balance is sufficient THEN the Edge Function SHALL debit the block cost from the RevenueCat balance BEFORE minting the Deepgram token.
3.6. IF the Deepgram token grant fails after a successful debit THEN the Edge Function SHALL refund the debit and return HTTP 503.
3.7. WHEN a block is granted THEN the Edge Function SHALL record it in the `voice_blocks` table with the user id, grant time, and expiry.
3.8. IF an unexpired block already exists for the caller THEN the Edge Function SHALL return HTTP 409 and SHALL NOT grant a second block.
3.9. WHEN the client reaches 90% of the block duration THEN it SHALL request the next block and hold both tokens until the new Deepgram connection is confirmed open.
3.10. IF a block renewal fails with HTTP 402 THEN the system SHALL allow the current block to run to completion, then transition the session to the exhausted state.
3.11. WHEN a session ends within 30 seconds of a block being granted AND no detections occurred in that block THEN the system SHALL credit the block cost back to the user.
3.12. The Edge Function SHALL never return the Deepgram master API key to a client under any condition.

### Requirement 4: Credit purchase and balance

**User Story:** As a practitioner, I want to buy voice minutes inside the app and see my remaining balance, so that I am never surprised by the feature stopping.

#### Acceptance Criteria

4.1. WHEN the user opens the paywall THEN the system SHALL display the available credit packs with store-localised prices fetched from RevenueCat.
4.2. WHEN a purchase completes THEN the system SHALL invalidate the local virtual currency cache and refetch the balance before displaying it.
4.3. WHEN a first-time user opens the voice feature THEN the system SHALL grant 20 trial credits exactly once, keyed on the RevenueCat app user id.
4.4. WHILE a session is active AND the remaining balance falls to 20% of what it was at session start OR below 3 credits, whichever is greater, THE system SHALL display a non-blocking low-balance warning.
4.5. WHEN the balance reaches zero during a session THEN the system SHALL stop audio capture, preserve the count, and present the paywall.
4.6. IF a purchase is made while a session is in the exhausted state THEN the system SHALL offer to resume the same session with its existing count intact.
4.7. The system SHALL NOT grant credits from a client-side purchase callback alone. Grants SHALL originate from RevenueCat's validated purchase flow.

### Requirement 5: Degraded and offline behaviour

**User Story:** As a practitioner, I want a network problem not to destroy my tally, so that I can trust the app with a long practice.

#### Acceptance Criteria

5.1. WHEN the Deepgram connection drops unexpectedly or stops responding while audio is still flowing THEN the system SHALL preserve the current count, display a reconnecting state, and attempt reconnection with exponential backoff starting at 500 ms and capped at 8 seconds.
5.2. WHILE the system is in the reconnecting state THE tap counter SHALL remain enabled and SHALL contribute to the same session total.
5.3. IF reconnection does not succeed within 60 seconds THEN the system SHALL transition to the degraded state, stop audio capture, and inform the user that voice counting has paused.
5.4. WHEN reconnection succeeds within the current block THEN the system SHALL resume streaming without requesting a new block.
5.5. IF the device is offline when the user attempts to start a voice session THEN the system SHALL block the start, explain that voice counting requires a connection, and SHALL NOT consume credits.
5.6. WHEN the app is backgrounded during an active session THEN the system SHALL pause audio capture, close the Deepgram connection, preserve the count, and display a resume prompt on return.
5.7. WHILE audio frames are flowing, IF Deepgram sends no message for 20 seconds THEN the system SHALL treat the connection as unresponsive and reconnect it without restarting healthy microphone capture.

### Requirement 6: Manual correction and tap coexistence

**User Story:** As a practitioner, I want to correct the count when the app mishears, so that my final number is the number I actually believe.

#### Acceptance Criteria

6.1. WHILE a voice session is active THE tap-to-count control SHALL remain visible and functional.
6.2. WHEN the user taps the count control during a voice session THEN the system SHALL increment the session total and record the increment with source `manual`.
6.3. WHEN the user performs the decrement gesture THEN the system SHALL decrement the session total by one, to a floor of zero.
6.4. WHEN a session ends THEN the system SHALL display the total broken down by source (voice, manual) in the session summary.
6.5. The system SHALL maintain the session count locally as the authoritative display value, with detections acting as increments to it.

### Requirement 7: Session persistence and history

**User Story:** As a practitioner, I want my sessions saved, so that I can see my practice over time.

#### Acceptance Criteria

7.1. WHEN a session ends THEN the system SHALL persist a record containing the target phrase, start time, duration, voice count, manual count, and credits consumed.
7.2. IF the app terminates unexpectedly during a session THEN the system SHALL recover the count from local storage on next launch and offer to save it as a completed session.
7.3. WHILE a session is active THE system SHALL checkpoint the current count to local storage at least every 10 seconds.
7.4. WHEN the user views history THEN the system SHALL list sessions in reverse chronological order with phrase, date, and total.

### Requirement 8: Matching accuracy and tuning

**User Story:** As the app operator, I want to tune matching behaviour without shipping an app release, so that I can improve accuracy quickly as real usage data arrives.

#### Acceptance Criteria

8.1. WHEN the app starts THEN it SHALL fetch matcher configuration from a remote source, comprising at minimum the fuzzy match threshold, refractory multiplier, and normalisation rules.
8.2. IF the remote configuration fetch fails THEN the system SHALL use the last cached configuration, or compiled-in defaults if no cache exists.
8.3. The matcher SHALL treat as equivalent all of: contraction and expanded forms, straight and curly apostrophes, punctuation variants, and casing variants of the target phrase.
8.4. The matcher SHALL accept a candidate window when its token-level similarity to the target meets or exceeds the configured threshold, defaulting to 0.80.
8.5. The matcher SHALL operate only on finalised transcript segments and SHALL NOT count from interim results.
8.6. WHEN a window is accepted THEN the matcher SHALL consume the matched tokens so they cannot contribute to a subsequent match.

### Requirement 9: Privacy and consent

**User Story:** As a practitioner engaged in private devotional practice, I want to know and control what happens to my voice, so that I can trust the app with it.

#### Acceptance Criteria

9.1. WHEN the user first enables voice counting THEN the system SHALL display a disclosure stating that audio is transmitted to a third-party speech recognition provider during voice sessions.
9.2. THE system SHALL NOT transmit audio at any time other than during an explicitly started voice session.
9.3. WHILE audio is being transmitted THE system SHALL display a persistent, visually distinct recording indicator.
9.4. THE system SHALL NOT store raw audio to disk at any point.
9.5. WHERE diagnostic logging is offered, the system SHALL default it to off and SHALL require explicit opt-in before transmitting any transcript text off device.
9.6. WHEN diagnostic logging is enabled THEN the system SHALL upload only transcript segments and match decisions, never audio.
9.7. WHEN Deepgram connections are opened THEN the system SHALL set the model improvement program opt-out parameter.

### Requirement 10: Observability and cost control

**User Story:** As the app operator, I want to detect when credits sold and streaming time consumed diverge, so that abuse or bugs do not quietly cost me money.

#### Acceptance Criteria

10.1. WHEN a block is granted THEN the Edge Function SHALL log the user id, block id, credits debited, and timestamp.
10.2. WHEN a session ends THEN the client SHALL report the session id, blocks used, actual streamed seconds, and detection count to the Edge Function on a best-effort basis.
10.3. IF a session report is not received within the expected window THEN the system SHALL mark the blocks as unreconciled rather than treating them as an error.
10.4. THE Deepgram project SHALL be configured with a hard spend limit that bounds total exposure independently of application logic.
10.5. THE system SHALL expose a query that compares credits debited against Deepgram reported usage over a given period.
