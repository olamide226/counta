# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Counta is a minimalist Flutter app for counting mantras/prayers/affirmations during meditation. It's offline-first with local Hive storage, supports iOS/Android/macOS/Windows/Linux/Web, and uses Material 3.

## Common Commands

```bash
make setup              # flutter pub get + code generation (run first)
make test               # run all tests
make test-coverage      # run tests with coverage
make lint               # dart analyze
make format             # dart format
make build-runner       # regenerate Hive adapters (.g.dart files)
make run                # flutter run (default device)
make run-ios            # flutter run on iOS
make run-android        # flutter run on Android
```

Run a single test file:
```bash
flutter test test/providers/counter_provider_test.dart
```

**After modifying any Hive model or enum** (files with `@HiveType` annotations), you must run `make build-runner` to regenerate the `.g.dart` adapter files.

## Architecture

Clean Architecture with Riverpod, following this dependency flow:

```
domain/models → data/repositories → state/providers → ui/screens
                                  ↗
              core/services ------
```

- **domain/models/** — Business entities with `@HiveType` annotations for persistence. Immutable with `copyWith()`. Must never import Flutter. `buildSessionRecord()` (`session_record.dart`) is the one builder for a `CountSession`, used by both the checkpoint snapshot and the save sheet.
- **domain/counting/** — Voice-counting domain: the `CountingEngine` and `SpeechSocket` ports, `PhraseMatcher`, `PhraseNormaliser`, `TranscriptSegment`. Pure Dart, no plugins — this is what the unit tests exercise.
- **domain/validation/** — Input rules, e.g. `PhraseValidator` (2–12 normalised tokens).
- **data/repositories/** — Hive persistence layer. `SettingsRepository` (single document) and `SessionsRepository` (collection).
- **data/hive/** — Hive initialization, adapter registration, box opening.
- **state/providers/** — Riverpod providers plus `SessionController` (the `ChangeNotifier` that owns the authoritative session count). This is where business logic lives.
- **core/config/** — `BuildConfig`: the single source of truth for dev-vs-release behaviour (app name, whether debug tools are reachable).
- **core/services/** — Cross-cutting: `CounterAlertService` (threshold alerts), `TapFeedbackService` (audio/haptics), `NotificationService` (local push), `ScreenWakeService` (wakelock).
- **core/services/counting/** — Platform adapters implementing the domain ports: `AudioSource` (record plugin), `DeepgramSocket` (WebSocket), `CloudCountingEngine`, `TapCountingEngine`.
- **core/theme/** — `ThemeRegistry` with 5 color schemes, plus presentation extensions like `SoundModePresentation`.
- **ui/screens/** — Full pages using `ConsumerWidget`/`ConsumerStatefulWidget`.
- **ui/screens/debug/** — Dev-only tooling, gated behind `BuildConfig.showDebugTools`.
- **ui/sheets/** — Bottom sheets for alert config, save session, sound mode, recovery and the voice disclosure. All of them go through `showCountaSheet` / `CountaSheetBody` so they agree on insets; dialogs belong in `ui/widgets/`, not here.
- **ui/widgets/** — Reusable components (count display, tap zone, controls bar, voice session banner, session summary card, microphone-denied dialog).

**Layer rule:** dependencies point inward. `domain/` imports nothing from `core/`, `data/`, `state/`, or `ui/`, and never imports Flutter or a plugin. Adapters in `core/services/counting/` implement the ports declared in `domain/counting/`.

## Voice counting

Two engines implement `CountingEngine`: `TapCountingEngine` (default) and `CloudCountingEngine` (streaming STT). `SessionController` owns the whole voice lifecycle — screens call `startVoiceSession(phrase)` / `stopVoiceSession()` and never swap engines themselves. `startVoiceSession` consults the disclosure gate, installs the voice engine from the injected factory, and on any terminal status (`permissionDenied`, `error`, `exhausted`) disposes the failed engine, rolls the phrase and start time back, and falls back to tap counting. It returns the status the attempt ended at, which is what the screen reacts to. `setEngine()` disposes the engine it replaces.

The third-party audio disclosure is gated on the voice-start flow, not on a screen: `SessionController.disclosureGate` is supplied by the app shell (`app.dart`), which owns the navigator the sheet needs. This keeps the UI dependency pointing inward.

The interface carries `counts`, `status`, `diagnostics`, `incrementManual()` and `decrementManual()` — add capabilities here rather than type-checking for a concrete engine.

`CloudCountingEngine` retries dropped connections for `reconnectWindow` (default 5 min) with jittered backoff, because sessions run 1–2 hours. A socket drop reconnects without restarting the microphone; only a mic stall (`AudioSourceStalled`) restarts capture.

**`AudioSource` is the single owner of the microphone permission.** It asks (the `record` plugin prompts as part of `hasPermission()`) and reports a refusal as a typed `AudioSourcePermissionDenied` on the same error channel as `AudioSourceStalled`. Nothing else may ask — a second question races the first. Capture therefore starts *before* the socket, and has to deliver a real frame before anything is connected, so no streaming time is ever spent on a session that cannot capture audio; frames captured during that window are buffered and flushed on connect. `openMicrophoneSettings()` (`core/services/microphone_settings.dart`) is the only permission UI: it sends the user to system settings, which on iOS is the only way to change a refusal.

**Platform requirements:** iOS declares `UIBackgroundModes: audio` so sessions survive backgrounding, and `AudioSource` sets `allowHapticsAndSystemSoundsDuringRecording` — without it the app's own tap sounds raise an audio-session interruption that permanently pauses recording. Android background recording is **not** supported yet: it needs a foreground service, which `record_android` does not provide.

**Credentials and blocks:** `CloudCountingEngine` never reads `DEEPGRAM_API_KEY` itself. The only reader of that define is `core/config/dev_secrets.dart`, which throws unless `BuildConfig.showDebugTools` is on. A configured build passes a `BlockService` instead: the engine buys a block before opening any socket, renews at 90% of the block, and releases on stop. `BlockClient` (`core/services/counting/block_client.dart`) is the only thing that talks to the `voice-block` Edge Function under `supabase/` (see `supabase/README.md`; `make supabase-test` runs its Deno tests), and maps every documented status onto a `BlockFailure` subtype declared in `domain/counting/block_service.dart`. Exactly one credential source is wired at a time — a build with a block service never falls back to the dev key.

A **renewal** opens the next connection and confirms it before closing the outgoing one, and both stream the same audio for `renewalOverlap`. That is why `PhraseMatcher` keeps a token window *per transcript stream* and rebases each onto the session timeline: every Deepgram connection numbers its own audio from zero. The engine derives each stream's offset from bytes streamed, not from a clock, so the two copies of a repetition land on the same span and the acceptance gate counts it once. The same rebase is what makes counting survive a **reconnect**, which also restarts the provider's clock. A reconnect reuses the current block and never acquires another — the server would read a grant carrying the live block's session id as a renewal and debit for it. It mints a fresh credential for that same block through `BlockService.refreshToken` (`POST .../voice-block/token`), which never debits: a block's own token lives ~30 s and only authorises *establishing* a connection, so replaying it could recover nothing but a drop in the block's first tenth. `BlockNotFound` (404) there means the block is gone and the session ends rather than retrying.

Every terminal end — a failed start, a reconnect that ran out of window, an expired block — goes through `_endStreaming`, the one place that sets `_stopped`, cancels the timers, stops capture, closes the sockets and releases *every* block the session holds. Anything that reports a status without it leaves a renewal timer armed, and an engine nobody disposed goes on buying blocks with no microphone attached.

## Key Provider Structure

- `counterProvider` — `StateNotifierProvider<CounterNotifier, CounterState>`: active counting session (increment, decrement, reset, threshold, alerts)
- `sessionControllerProvider` — `ChangeNotifierProvider<SessionController>`: owns the authoritative count. `CounterState.count` mirrors it; the controller is the single writer.
- `voiceEngineFactoryProvider` / `tapEngineFactoryProvider` — build `CountingEngine`s so the UI never constructs platform stacks
- `settingsProvider` — `StateNotifierProvider<SettingsNotifier, AppSettings>`: persisted app settings (theme, sound, defaults)
- `sessionsProvider` — saved session list from Hive
- `screenWakeServiceProvider` — holds the wakelock while a voice session is in the foreground
- `hiveInitProvider` — `FutureProvider` for async Hive initialization at startup
- `sessionStartupProvider` — `FutureProvider<CountSession?>`: takes the previous run's checkpoint, then attaches the checkpointer. Watched by `App`; must run before anything counts
- `supabaseSessionProvider` — `FutureProvider<Session?>`: initialises Supabase from `SUPABASE_URL` / `SUPABASE_PUBLISHABLE_KEY` dart-defines and signs in anonymously; null when the build has no backend config
- `blockServiceProvider` — `Provider<BlockService?>`: the `BlockClient`, or null when the build has no Supabase config. `deepgramTokenProviderProvider` is the fallback for that case only (dev key via `DevSecrets`, else `VoiceUnavailable`)
- `appLifecycleProvider` — handles background/foreground transitions; shows an ongoing notification for a backgrounded voice session instead of a resume prompt

## Hive Persistence

Three Hive boxes: `'settings'` (single `AppSettings` doc), `'sessions'` (collection of `CountSession` docs) and `'session_checkpoint'` (at most one `CountSession`: the session in progress). Type IDs: `AppSettings`=0, `CountSession`=1, `SoundMode`=10, `ThemeModeChoice`=11, `AppThemeId`=12.

`CountSession` fields 12–14 (`phrase`, `voiceCount`, `manualCount`) are nullable so sessions saved before voice counting existed still load. Field 15 `completed` defaults to `true` for the same reason; it is `false` on a record recovered from a checkpoint. Field 16 `creditsConsumed` is nullable until block accounting exists.

**Startup order matters.** `sessionStartupProvider` (`state/providers/session_recovery.dart`) is the app's first step, kicked off from `App`: it calls `SessionCheckpointStore.take()` — read *and* delete — and only then attaches `SessionCheckpointer`. Reading without deleting, or attaching the checkpointer first, lets the first count of the new launch overwrite the crashed run's record before the user has decided anything. The provider exposes the pending `CountSession?`; `CounterScreen` only reacts to it to show `RecoverSessionSheet`. Never read `sessionCheckpointerProvider` from a screen.

`SessionCheckpointer` writes at most once per 10 s, and only when the *persisted* content changed (total, voice/manual split, phrase). Engine status is not persisted, so status churn costs nothing; an idle session holds no timer at all. Because the startup step has already emptied the store, clearing is unconditional.

Retiring a checkpoint happens in exactly one place: `SessionsNotifier.saveSession`. Save paths must not clear it themselves.

## Testing

Tests live in `test/` mirroring `lib/` structure. Uses `ProviderContainer` with mock overrides. Core business logic (counter provider, alert service, models, themes) is tested; UI and platform services are not.

Shared doubles live in `test/helpers/` — use them rather than growing another copy: `InMemoryCheckpointStore`, `FakeCountingEngine` (configurable `startStatus`, records starts/manual calls/disposal), `testSession(...)`, `withTempHive()`, and the settings/sessions/service mocks. `voice_fakes.dart` holds `FakeSpeechSocket`, `FakeAudioSource` and `FakeBlockService`; because it reaches the `record` plugin through `AudioSource`, the plugin-free `finalSegment(...)` / `testPhrase` live in `transcript_fixtures.dart` (re-exported by the fakes) so the `domain/` tests can import them too.

## Conventions

- Riverpod for all state management — no `setState` for shared state
- Material 3 theming via `ThemeRegistry.buildTheme(AppThemeId, Brightness)`
- Commit messages follow conventional commits (`feat:`, `fix:`, `refactor:`, `chore:`, `patch:`)
- Hive models use generated adapters — never hand-write `.g.dart` files
