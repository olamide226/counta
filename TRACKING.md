# Mantra Counter App — Execution Plan

Owner: Ola  
Date: 2026-01-27  
Status: In progress

## Milestone 1 — Project Bootstrap
- [x] Add dependencies (Riverpod, Hive, audioplayers, vibration, go_router optional)
- [ ] Configure assets (tap + alert sounds placeholders)
- [x] Create base app entry (`main.dart`, `app.dart`)
- [x] Define core enums and models
- [x] Initialize Hive and repositories
- [x] Create settings provider with defaults

**Acceptance checks**
- App runs with a basic home screen
- Hive opens boxes without errors

## Milestone 2 — Counter MVP
- [x] Implement `CounterState` and `counterProvider`
- [x] Build `CounterScreen` layout
- [x] Implement `ResizableTapLayout` + `TapZone`
- [x] Implement `TapFeedbackService`
- [x] Implement alert logic + in‑app feedback

**Acceptance checks**
- Tap increments reliably
- Drag handle resizes tap zone and persists ratio
- Alerts fire on threshold and repeat interval

## Milestone 3 — Sessions
- [x] Implement `CountSession` model + adapter
- [x] Implement sessions repository
- [x] Add Save Session flow (sheet + persistence)
- [x] Build Sessions list + details

**Acceptance checks**
- Sessions save and display correctly

## Milestone 4 — Settings & Themes
- [x] Build theme system and registry
- [x] Implement Settings screen
- [x] Wire theme mode + theme id persistence

**Acceptance checks**
- Theme switching works across app

## Milestone 5 — Polish & Quality
- [ ] Add count bump animation
- [ ] Accessibility pass (text size + targets)
- [ ] Add tests for alert logic and providers

**Acceptance checks**
- Tests pass for alert logic and providers

## Dependencies
- flutter_riverpod
- hive, hive_flutter
- hive_generator, build_runner
- audioplayers
- vibration (optional)
- go_router (optional)

## Decisions & Assumptions
- Default `tapZoneRatio = 0.75`
- `soundMode = vibrate` by default
- `confirmReset = true`
- `defaultThreshold = 100`
- `defaultRepeatInterval = 100`

## Backlog (Post‑v1)
- Auto‑save sessions on reset/exit
- Stats dashboards
- Multiple counters/profiles
- Import/export JSON
- Wearable companion
- Cloud sync
