# Mantra Counter App — Execution Plan

Owner: Ola  
Date: 2026-01-27  
Status: In progress

## Milestone 1 — Project Bootstrap
- [ ] Add dependencies (Riverpod, Hive, audioplayers, vibration, go_router optional)
- [ ] Configure assets (tap + alert sounds placeholders)
- [ ] Create base app entry (`main.dart`, `app.dart`)
- [ ] Define core enums and models
- [ ] Initialize Hive and repositories
- [ ] Create settings provider with defaults

**Acceptance checks**
- App runs with a basic home screen
- Hive opens boxes without errors

## Milestone 2 — Counter MVP
- [ ] Implement `CounterState` and `counterProvider`
- [ ] Build `CounterScreen` layout
- [ ] Implement `ResizableTapLayout` + `TapZone`
- [ ] Implement `TapFeedbackService`
- [ ] Implement alert logic + in‑app feedback

**Acceptance checks**
- Tap increments reliably
- Drag handle resizes tap zone and persists ratio
- Alerts fire on threshold and repeat interval

## Milestone 3 — Sessions
- [ ] Implement `CountSession` model + adapter
- [ ] Implement sessions repository
- [ ] Add Save Session flow (sheet + persistence)
- [ ] Build Sessions list + details

**Acceptance checks**
- Sessions save and display correctly

## Milestone 4 — Settings & Themes
- [ ] Build theme system and registry
- [ ] Implement Settings screen
- [ ] Wire theme mode + theme id persistence

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
- `defaultThreshold = 108`
- `defaultRepeatInterval = 108`

## Backlog (Post‑v1)
- Auto‑save sessions on reset/exit
- Stats dashboards
- Multiple counters/profiles
- Import/export JSON
- Wearable companion
- Cloud sync
