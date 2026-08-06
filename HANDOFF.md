# Session handoff — voice counting work

Written at the end of a long session. Everything below is **uncommitted** in the
working tree on `main` (HEAD is `53d3417 chore: bump version to 0.1.1`).

## Your job, in order

1. **Commit the work** (52+ changed paths, nothing committed yet — see *Committing* below)
2. **Upgrade Flutter** 3.41.4 → 3.44+ (see *Step 2*)
3. **Add the Live Activity widget extension** (see *Step 3*)

Do not start 2 until 1 is done and the tree is clean — the upgrade is the most
likely thing to break the build, and you want a revert point.

---

## Current state

| | |
|---|---|
| Branch | `main`, 52 uncommitted paths |
| Version | `0.1.2+6` |
| Flutter | 3.41.4 stable |
| Min iOS | 15.0 |
| Tests | 135 passing, 2 skipped (fixture gates, waiting on recordings) |
| `flutter analyze` | clean — 11 pre-existing infos, 0 warnings, 0 errors |
| Last build | `build/ios/ipa/counta.ipa`, verified, **not yet uploaded** |

Verify before you start: `flutter analyze && flutter test`.

---

## What this session changed

### Bug fixes (all have regression tests)

- **iOS build was broken.** `record` 5.2.1 pins `record_linux` to `<1.0.0`, which
  resolves to 0.7.2 — written against an older `record_platform_interface` than
  the 1.6.0 `record` itself pulls in. Flutter's generated
  `dart_plugin_registrant.dart` imports every platform impl unconditionally, so a
  Linux plugin broke the iOS build. Fixed with a `dependency_overrides` pin to
  `record_linux: 1.3.1`. **Drop the override when moving to `record >= 6.2.1`.**

- **Microphone died mid-session.** `record_darwin`'s interruption observer calls
  `pause()` on `.began` and has no `.ended` handler, so capture never resumed.
  The app's own tap sounds were triggering the interruption. Fixed by setting
  `allowHapticsAndSystemSoundsDuringRecording: true`.

- **Stop button did nothing.** `AudioSource.stop()` ran twice concurrently
  (the broadcast controller's `onCancel` re-entered it), racing two native
  `AudioRecorder.stop()` calls. Fixed by memoising the in-flight stop; all UI
  state updates moved into `finally`.

- **Manual taps lost during voice sessions.** `SessionController` had
  `if (_engine is TapCountingEngine)` guards, so `CloudCountingEngine.incrementManual()`
  was never called. Fixed by hoisting `incrementManual`/`decrementManual`/`diagnostics`
  onto the `CountingEngine` interface.

- **Continuing a saved session collapsed the count.** `loadSession` reset the
  controller to 0 while showing N; the next tap read `total` → 1. Added
  `SessionController.seed()`.

- **Layout overflows** in `QuickControlsBar` (223px) and the debug screen
  (vertical + two horizontal). Both have viewport-range widget tests.

- **Recording paused the user's music.** `.playAndRecord` without
  `mixWithOthers` takes the audio route exclusively. Fixed; asserted in
  `test/services/counting/audio_source_config_test.dart`.

### Architecture

`lib/counting/` was dissolved — it had flattened all four layers into one folder,
and `domain/validation/` was importing it, so domain depended on plugin code.
Now: `domain/counting/` (pure), `core/services/counting/` (adapters),
`state/providers/session_controller.dart`, `ui/screens/debug/`.
CLAUDE.md documents the layout and the layer rule.

### Features

- Long-session reconnect: time-based budget (5 min), jittered backoff capped at
  15s, socket drops don't restart the mic
- Latency instrumentation in the debug screen (interim vs final, median/p95)
- Background audio (`UIBackgroundModes: audio`) + wakelock + ongoing notification
- `CountSession` gained `phrase`, `voiceCount`, `manualCount` (fields 12–14,
  nullable so old records still load)
- Dev builds are `com.ruach-tech.counta.dev` / "Counta Dev"; release unchanged.
  Debug tools are compile-time gated and **tree-shaken out of release** (verified
  by grepping the IPA binary).

---

## Committing (step 1)

52 paths. Suggested split — check `git diff` yourself, don't trust this blindly:

```
fix(ios): pin record_linux to unbreak the iOS build
refactor(counting): move lib/counting into documented layers
fix(counting): keep the mic alive and make stop reliable
feat(counting): long-session reconnect and diagnostics
feat(session): record phrase and voice/tap split
feat(ios): background audio, wakelock, ongoing notification
fix(ui): layout overflows in controls bar and debug screen
feat(debug): latency instrumentation and fixture export
chore(ios): min iOS 15.0, dev bundle id, Counta Dev naming
docs: update CLAUDE.md for the new structure
```

Repo convention is conventional commits (see CLAUDE.md).

**Note:** `specs/` is untracked and contains the product spec. Confirm with the
user whether it should be committed — it was already in the tree when this
session started and may be intentionally local.

---

## Step 2 — Flutter upgrade

Goal: 3.41.4 → 3.44+ so `live_activities` 2.5.1 can be used (2.4.9 works on
3.41 if the upgrade goes badly and you want to back out).

**Why this is the risky step.** This project's iOS build already broke once from
a transitive plugin/interface mismatch (`record_linux`, above). A Flutter bump
moves every plugin constraint at once.

Sequence:
1. `flutter upgrade`
2. `flutter pub upgrade --major-versions`
3. **Try removing the `record_linux` override** — if `record` resolved to
   `>= 6.2.1`, it's fixed upstream and the override should go. If you keep
   `record` at 5.2.1, keep the override.
4. `flutter analyze && flutter test` (expect 135 passing)
5. `flutter build ios --debug --no-codesign` — the real check
6. `cd ios && pod install`

If `record` goes to 6.x or 7.x, `AudioSource.recordConfig` and `startStream`
may need updating — those are breaking majors.

Also check: `flutter build ipa` still reports `Deployment Target: 15.0`, and
`MinimumOSVersion` in the built app is 15.0. Flutter hardcodes App.framework's
minimum at `packages/flutter_tools/lib/src/darwin/darwin.dart` (`Version(13,0)`)
and overwrites `AppFrameworkInfo.plist` with `plutil -replace` at build time —
a newer Flutter may raise that, which would be a bonus.

---

## Step 3 — Live Activity / Dynamic Island

**Read this first:** the user asked to "show the app icon instead of the mic icon"
in the Dynamic Island. That is **not possible** — the mic indicator is a system
privacy indicator, drawn by iOS, not replaceable by apps. This was explained and
accepted. What we're building is a **Live Activity that sits alongside it**,
showing Counta's icon and the live count.

Work:
1. New **Widget Extension** target in Xcode (SwiftUI + ActivityKit). The project
   has **no** extension target today (only app + unit tests) and **no**
   entitlements file — this is greenfield.
2. **App Group** entitlement on both targets, to share state.
3. `live_activities: ^2.5.1` (after the Flutter upgrade).
4. `NSSupportsLiveActivities` = `YES` in `ios/Runner/Info.plist`.
5. Dart wiring: start on session start, end on stop, update on count change.

**Design constraint that will bite you:** ActivityKit throttles updates. You
**cannot** push one per count. Decide a cadence — every N counts or every few
seconds — and make it explicit rather than discovering the throttle in testing.

**Availability:** Live Activities are iOS 16.1+; min deployment is 15.0. Guard
the calls, don't raise the minimum.

Only verifiable on a physical device. Requires a re-upload after.

---

## Known open items (not blockers, but real)

- **Deepgram API key is hardcoded** in `CloudCountingEngine` and **extractable
  from the release IPA** (verified by grepping the binary). Spec task 8.4 removes
  it. Fine for internal TestFlight; not for external testers.
- **`PhraseHistoryRepository` / `PhraseHistoryEntry` are orphaned** — no provider,
  Hive box never opened, `PhraseSetupScreen.recentPhrases` never passed. The
  "Recent Phrases" UI is dead. Wire it or delete it.
- **`phrase_setup_screen.dart` hardcodes `Colors.deepPurple` / `Colors.grey`**,
  ignoring `ThemeRegistry`.
- **Android background recording does not work.** Needs a foreground service;
  `record_android` provides none. iOS works.
- **Launch image is still the default placeholder** (flagged by every build).
- **Build numbers are uncertain.** A build outside this session used `5`;
  `pubspec` is now `+6`. Check TestFlight's build list before uploading —
  Xcode cached a stale Info.plist once already and reported 5 when the config
  said 4. If ASC rejects as duplicate, bump and rebuild.

---

## Task 3 (accuracy baseline) is unblocked and waiting on recordings

The user needs to record six fixtures via the debug screen. Recipe is in
[test/fixtures/transcripts/README.md](test/fixtures/transcripts/README.md).
The export now embeds `true_count`, so files land committable.

**Warn them before they read results:** a synthetic 100-rep fixture with perfect
transcripts scored **50% recall**, because `refractoryFloorMs = 1200` demands
1.2s of silence between reps and suppresses every other one at normal chanting
pace. A sweep confirmed 1000ms → 100%. If `normal_100` comes back near 50%, it's
that constant, not the approach failing. `test/fixtures/tuning_sweep_test.dart`
sweeps it. Tuning is task 4.7 and needs the real corpus — don't change the
constant on a guess.
