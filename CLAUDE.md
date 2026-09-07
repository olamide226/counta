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

- **domain/models/** — Business entities with `@HiveType` annotations for persistence. Immutable with `copyWith()`. Must never import Flutter.
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
- **ui/sheets/** — Bottom sheets for alert config, save session, sound mode.
- **ui/widgets/** — Reusable components (count display, tap zone, controls bar, voice session banner).

**Layer rule:** dependencies point inward. `domain/` imports nothing from `core/`, `data/`, `state/`, or `ui/`, and never imports Flutter or a plugin. Adapters in `core/services/counting/` implement the ports declared in `domain/counting/`.

## Voice counting

Two engines implement `CountingEngine`: `TapCountingEngine` (default) and `CloudCountingEngine` (streaming STT). `SessionController.setEngine()` swaps between them; screens get engines from `voiceEngineFactoryProvider` / `tapEngineFactoryProvider` rather than constructing them.

The interface carries `counts`, `status`, `diagnostics`, `incrementManual()` and `decrementManual()` — add capabilities here rather than type-checking for a concrete engine.

`CloudCountingEngine` retries dropped connections for `reconnectWindow` (default 5 min) with jittered backoff, because sessions run 1–2 hours. A socket drop reconnects without restarting the microphone; only a mic stall (`AudioSourceStalled`) restarts capture.

**Platform requirements:** iOS declares `UIBackgroundModes: audio` so sessions survive backgrounding, and `AudioSource` sets `allowHapticsAndSystemSoundsDuringRecording` — without it the app's own tap sounds raise an audio-session interruption that permanently pauses recording. Android background recording is **not** supported yet: it needs a foreground service, which `record_android` does not provide.

**Credentials:** `CloudCountingEngine` takes a required `tokenProvider` and never reads `DEEPGRAM_API_KEY` itself. The only reader of that define is `core/config/dev_secrets.dart`, which throws unless `BuildConfig.showDebugTools` is on. Production tokens come from the `voice-block` Supabase Edge Function under `supabase/` (see `supabase/README.md`; `make supabase-test` runs its Deno tests).

## Key Provider Structure

- `counterProvider` — `StateNotifierProvider<CounterNotifier, CounterState>`: active counting session (increment, decrement, reset, threshold, alerts)
- `sessionControllerProvider` — `ChangeNotifierProvider<SessionController>`: owns the authoritative count. `CounterState.count` mirrors it; the controller is the single writer.
- `voiceEngineFactoryProvider` / `tapEngineFactoryProvider` — build `CountingEngine`s so the UI never constructs platform stacks
- `settingsProvider` — `StateNotifierProvider<SettingsNotifier, AppSettings>`: persisted app settings (theme, sound, defaults)
- `sessionsProvider` — saved session list from Hive
- `screenWakeServiceProvider` — holds the wakelock while a voice session is in the foreground
- `hiveInitProvider` — `FutureProvider` for async Hive initialization at startup
- `supabaseSessionProvider` — `FutureProvider<Session?>`: initialises Supabase from `SUPABASE_URL` / `SUPABASE_PUBLISHABLE_KEY` dart-defines and signs in anonymously; null when the build has no backend config. `deepgramTokenProviderProvider` supplies the engine's credential (dev key via `DevSecrets` in dev builds only; the block client in task 9 replaces it)
- `appLifecycleProvider` — handles background/foreground transitions; shows an ongoing notification for a backgrounded voice session instead of a resume prompt

## Hive Persistence

Two Hive boxes: `'settings'` (single `AppSettings` doc) and `'sessions'` (collection of `CountSession` docs). Type IDs: `AppSettings`=0, `CountSession`=1, `SoundMode`=10, `ThemeModeChoice`=11, `AppThemeId`=12.

`CountSession` fields 12–14 (`phrase`, `voiceCount`, `manualCount`) are nullable so sessions saved before voice counting existed still load.

## Testing

Tests live in `test/` mirroring `lib/` structure. Uses `ProviderContainer` with mock overrides. Core business logic (counter provider, alert service, models, themes) is tested; UI and platform services are not.

## Conventions

- Riverpod for all state management — no `setState` for shared state
- Material 3 theming via `ThemeRegistry.buildTheme(AppThemeId, Brightness)`
- Commit messages follow conventional commits (`feat:`, `fix:`, `refactor:`, `chore:`, `patch:`)
- Hive models use generated adapters — never hand-write `.g.dart` files
