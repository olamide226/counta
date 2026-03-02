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

- **domain/models/** — Business entities with `@HiveType` annotations for persistence. Immutable with `copyWith()`.
- **data/repositories/** — Hive persistence layer. `SettingsRepository` (single document) and `SessionsRepository` (collection).
- **data/hive/** — Hive initialization, adapter registration, box opening.
- **state/providers/** — Riverpod `StateNotifierProvider`s for counter logic, settings, sessions, app lifecycle. This is where business logic lives.
- **core/services/** — Cross-cutting: `CounterAlertService` (threshold alerts), `TapFeedbackService` (audio/haptics), `NotificationService` (local push).
- **core/theme/** — `ThemeRegistry` with 5 color schemes, Material 3 `ColorScheme.fromSeed()`.
- **ui/screens/** — Full pages using `ConsumerWidget`/`ConsumerStatefulWidget`.
- **ui/sheets/** — Bottom sheets for alert config, save session, sound mode.
- **ui/widgets/** — Reusable components (count display, tap zone, controls bar).

## Key Provider Structure

- `counterProvider` — `StateNotifierProvider<CounterNotifier, CounterState>`: active counting session (increment, decrement, reset, threshold, alerts)
- `settingsProvider` — `StateNotifierProvider<SettingsNotifier, AppSettings>`: persisted app settings (theme, sound, defaults)
- `sessionsProvider` — saved session list from Hive
- `hiveInitProvider` — `FutureProvider` for async Hive initialization at startup
- `appLifecycleProvider` — handles background/foreground transitions, schedules resume notifications

## Hive Persistence

Two Hive boxes: `'settings'` (single `AppSettings` doc) and `'sessions'` (collection of `CountSession` docs). Type IDs: `AppSettings`=0, `CountSession`=1, `SoundMode`=10, `ThemeModeChoice`=11, `AppThemeId`=12.

## Testing

Tests live in `test/` mirroring `lib/` structure. Uses `ProviderContainer` with mock overrides. Core business logic (counter provider, alert service, models, themes) is tested; UI and platform services are not.

## Conventions

- Riverpod for all state management — no `setState` for shared state
- Material 3 theming via `ThemeRegistry.buildTheme(AppThemeId, Brightness)`
- Commit messages follow conventional commits (`feat:`, `fix:`, `refactor:`, `chore:`, `patch:`)
- Hive models use generated adapters — never hand-write `.g.dart` files
