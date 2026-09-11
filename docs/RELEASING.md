# Releasing Counta

How a Counta build gets from a clean checkout to users on Android and iOS.
Written so that someone who forks this repository can ship their own copy.

The reasoning behind the cadence, the Play App Signing model, the CI secret
setup and the known limitations lives in
**[RELEASE-BACKGROUND.md](RELEASE-BACKGROUND.md)**. This file is the part you
follow.

This app's store listings are not in the repository. The owner's Play Console
first-submission walkthrough is `docs/play-submission.internal.md`, gitignored
on purpose.

---

## 1. Versioning

One line in `pubspec.yaml` is the source of truth for both platforms:

```yaml
version: 0.2.0+1
#        ^^^^^ ^
#        │     └── build number   (n)  → Android versionCode, iOS CFBundleVersion
#        └──────── version name   (x.y.z) → Android versionName, iOS CFBundleShortVersionString
```

Nothing hardcodes either value — Gradle, `Info.plist` and the Live Activity
extension all read them from Flutter. Override either at build time with
`--build-name` / `--build-number` instead of editing `pubspec.yaml`.

### The one rule you cannot break

**The build number must strictly increase on every upload to either store, and
can never be reused or lowered.**

Not per release — per *upload*. If you upload `0.3.0+7` and find a bug before
promoting it, the replacement is `0.3.0+8`, not another `+7`. Play rejects a
duplicate `versionCode` outright; App Store Connect rejects a `CFBundleVersion`
that is not higher than the last build of the same short version. Both stores
count forever, including builds you deleted or never released. The two stores
keep separate counters; treat the number in `pubspec.yaml` as global anyway,
because one number is far easier to reason about than two.

The version name has no such rule. Semver applies: `x` for a breaking change to
saved data or behaviour, `y` for a user-visible feature, `z` for fixes.

### `version-bump.yml`

A manual `workflow_dispatch`. Pick `patch` / `minor` / `major`; it rewrites the
`version:` line, increments the build number by one, commits, and pushes a
`vX.Y.Z` tag, which triggers `release.yml`.

- It needs a `RELEASE_PAT` secret (a PAT with `contents: write`). The default
  `GITHUB_TOKEN` will not do — a push made with it does not trigger other
  workflows, so the tag would land and `release.yml` would never fire.
- **It bumps once per version bump, not once per upload.** Right for starting a
  release, wrong for replacing a build you already uploaded. For that, edit
  `+n` by hand or pass `--build-number`.

---

## 2. Signing, at build time

Creating the upload key is a once-ever setup task and lives in
[RELEASE-BACKGROUND.md](RELEASE-BACKGROUND.md), "Android release signing",
along with the Play App Signing model you need to understand first.

What matters on a release day: **when `android/key.properties` is absent or any
of its four fields is blank**, `flutter run --release` and `make build-android`
still work — the release build falls back to the debug signing config and
Gradle says so. `make build-appbundle` refuses that fallback and fails at
configuration time, rather than producing an AAB that Play rejects an hour
later.

Check what actually signed an artifact — `CN=Android Debug` means the fallback
was taken:

```bash
$ANDROID_HOME/build-tools/<ver>/apksigner verify --print-certs \
  build/app/outputs/flutter-apk/app-release.apk
```

---

## 3. Build commands

| Command | Produces | For |
| --- | --- | --- |
| `make build-appbundle` | `build/app/outputs/bundle/release/app-release.aab` | Google Play. Requires the upload key. |
| `make build-android` | `build/app/outputs/flutter-apk/app-release.apk` | Direct download, the GitHub release, sideloading. |
| `make build-ios-ipa` | `build/ios/archive/Runner.xcarchive` | App Store Connect / TestFlight. |
| `make release-preflight` | nothing | The gate before you tag (§4). |

### Compile-time configuration

Dev and published builds do not take the same defines, and the difference is a
security boundary rather than a convenience.

`DART_DEFINES` (`make run`, `make build-web`) forwards the whole `.env` file
when there is one. `RELEASE_DART_DEFINES` — every release-mode artifact that
leaves your machine, including the APK — forwards the same keys **minus
`DEEPGRAM_API_KEY`**.

The reason is that a `--dart-define` is embedded in the artifact even when the
Dart-side read is compile-time dead, so a release build made with
`--dart-define-from-file=.env` ships the Deepgram master key to anyone who
unzips it. **Never point a store build at `.env`.** The Makefile states the
exclusion once, as a `filter-out`; CI gets the same behaviour by calling these
targets with the secrets exported as environment variables.

Both Supabase values are public client configuration and safe to embed. A build
without them is valid; it simply has no backend.

---

## 4. Preflight checklist

Run before every tag. `make release-preflight` does the first three.

- [ ] `git status` is clean and you are on `main`, up to date with `origin`.
- [ ] `make lint` passes. Eight `deprecated_member_use` infos about `Radio` in
      `settings_screen.dart` and `sound_mode_sheet.dart` are known and expected;
      anything else is not.
- [ ] `make test` passes. This includes `test/fixtures/corpus_test.dart`, the
      transcript recall gates — the only automated check on counting accuracy.
      A regression there ships a counter that miscounts.
- [ ] `pubspec.yaml` build number satisfies §1's rule.
- [ ] `CHANGELOG.md` has an entry for this version.
- [ ] **Android permission strings.** Confirm the merged set with
      `aapt2 dump badging <apk> | grep uses-permission` and check every entry
      against your Play data safety declaration. `AndroidManifest.xml` declares
      `RECORD_AUDIO`, `POST_NOTIFICATIONS` and `INTERNET`; plugins add
      `VIBRATE`, `WAKE_LOCK`, `ACCESS_NETWORK_STATE` and
      `com.google.android.c2dm.permission.RECEIVE` (see RELEASE-BACKGROUND.md
      on the FCM dependency).
- [ ] **iOS permission strings.** `ios/Runner/Info.plist` still has a non-empty
      `NSMicrophoneUsageDescription` and `UIBackgroundModes` containing `audio`.
      Review rejects a missing or generic usage string, and dropping the
      background mode silently kills long voice sessions.
- [ ] Store metadata that changed this release (screenshots, description,
      what's-new text) is ready in both consoles.
- [ ] You have re-read §7 and none of those limitations became worse.

---

## 5. Run books

### 5a. Android

1. **Preflight.** `git checkout main && git pull && make release-preflight`.
   Fix anything red. Do not proceed with a dirty tree.
2. **Bump the version.** Either the *Version Bump* workflow in the Actions tab,
   or edit `version:` and tag by hand (§1).
3. **Build the bundle.** `make build-appbundle`. It fails immediately if the
   upload key is missing or half-configured.
4. **Sanity-check the artifact.** From the APK of the same commit
   (`make build-android`):
   ```bash
   aapt2 dump badging build/app/outputs/flutter-apk/app-release.apk \
     | grep -E "^package:|targetSdkVersion"
   ```
   Confirm `versionCode`, `versionName` and `targetSdkVersion`, and that
   `apksigner --print-certs` (§2) does **not** say `CN=Android Debug`.
5. **Upload to internal testing.** Play Console › Testing › Internal testing ›
   Create new release › upload the AAB › release notes › Review › Start
   rollout. It reaches testers within minutes.
6. **Test on a real device from the store install**, not from `flutter run`.
   Walk the paths that only break in release: first launch with no saved data,
   granting and denying the microphone permission, a voice session, a long tap
   session backgrounded and resumed, the Live Activity ending when the session
   ends, and a session saved and reloaded after a cold start.
7. **Soak** for the period in RELEASE-BACKGROUND.md for this release kind.
8. **Promote to closed testing.** Internal testing › the release › Promote.
   Same artifact, no rebuild — promotion moves the build you already tested,
   which is the entire point of tracks.
9. **Promote to production with a staged rollout.** Set the percentage rather
   than accepting 100 %. Use the ladder for this release kind.
10. **Watch, then advance.** Play Console › Quality › Android vitals, filtered
    to the new version. One step at a time, at least 24 h apart. Halt and do
    not advance if crash-free sessions drop below **99.0 %** or more than
    0.5 pp below the previous release; ANR rate exceeds **0.47 %** (Play's own
    bad-behaviour threshold, above which it demotes you in search); any single
    new crash cluster affects more than **0.5 %** of sessions; or several
    reviews describe the same new problem. Reviews arrive later than vitals —
    check both.
11. **Reach 100 %,** update `CHANGELOG.md` if the workflow did not, and confirm
    the GitHub release has the artifacts you expect.

**Halting.** Play Console › Production › the release › **Halt rollout**. Users
who already received the build keep it — halting stops further distribution, it
does not claw anything back. Do it the moment a threshold trips; resuming is
cheap, a bad build spreading is not.

### 5b. iOS

1. **Preflight.** §4, plus: the signing certificate and provisioning profile in
   Xcode are valid and not about to expire, and the
   `CountaLiveActivityExtension` identifier still resolves to
   `$(APP_BUNDLE_ID).CountaLiveActivity`. iOS refuses to install an app whose
   appex identifier is not prefixed by the host app's, and it fails at install
   time, not build time.
2. **Confirm the archived configuration.** `ios/Flutter/AppIdentity.xcconfig`
   gives Debug and Profile the `.dev` bundle id and Release the published one.
   An archive built from Debug uploads under the wrong identifier.
3. **Archive.** `make build-ios-ipa`, then
   `open build/ios/archive/Runner.xcarchive` — or archive from Xcode (Product ›
   Archive) if you want the Organizer's validation step.
4. **Upload** from Xcode Organizer › Distribute App › App Store Connect.
   Processing takes 5–60 minutes.
5. **TestFlight internal.** Up to 100 team members, available as soon as
   processing finishes, **no review required**. Test here first, always.
6. **Export compliance.** The first upload of each version asks about
   encryption. Counta uses HTTPS/WSS only, which is exempt, but you must still
   answer. Adding `ITSAppUsesNonExemptEncryption=false` to `Info.plist` stops
   it blocking every build.
7. **TestFlight external** (recommended for a feature release). Requires a Beta
   App Review on the first build of each version — usually under 24 h, but
   budget a day. Later builds of the same version normally skip it.
8. **Submit for review.** Typically 24–48 h; assume longer near Apple's
   holiday shutdown in late December.
9. **Phased release.** In Release options choose *Release update over 7 days*.
   Apple's schedule is fixed: 1, 2, 5, 10, 20, 50, 100 % on days 1–7. You can
   pause it, and users can always update manually. Updates only — a first
   release goes to everyone at once.

What first rejections are actually about — usage strings, background audio,
reviewer access, privacy labels — is in RELEASE-BACKGROUND.md. Read it once
before your first submission.

---

## 6. Rollback

**You cannot un-ship a build.** Neither store removes a version from devices
that already installed it. Everything below limits the blast radius or moves
forward; nothing undoes. In order, fastest first:

1. **Halt the staged rollout** (Play: Production › Halt rollout. iOS: pause the
   phased release). Seconds to take effect, stops the build reaching anyone
   new. Always do this before you diagnose.
2. **Android only: roll back to a previous artifact.** Play lets you create a
   new production release from a previously uploaded bundle. Two catches: it
   needs a **new, higher `versionCode`**, so you upload the old *code* rebuilt
   with a bumped build number rather than the old AAB itself; and a user who
   already installed the bad version is **not** downgraded, because Android
   will not install a lower `versionName` over a higher one. This protects
   people who have not updated yet. It rescues nobody who has.
3. **Ship a fix forward.** For everyone already on the bad build this is the
   only real remedy. Hotfix cadence: patch bump, 12–24 h internal soak, then
   straight to 100 %. On iOS request **expedited review** (App Store Connect ›
   Contact Us › App Review) and describe the user impact concretely. Apple
   grants these for genuine crash-level bugs and remembers if you cry wolf.
4. **iOS only: remove the version from sale**, as a last resort. This stops new
   downloads entirely, including of the working previous version, and existing
   users keep the broken build. Almost never right.

---

## 7. CI, and what this release does not do

`release.yml` fires on a `v*.*.*` tag (or `workflow_dispatch` with a tag). It
creates a GitHub release and attaches an Android APK, a macOS `.dmg`, a Windows
`.zip`, and — when the four signing secrets exist — a signed AAB. It never
uploads to any store; moving an artifact to a console is always a human step.
Secret setup and the workflow's rough edges are in RELEASE-BACKGROUND.md.

The Flutter version is pinned once, as the workflow-level `FLUTTER_VERSION`.
**Keep it equal to the version you build with locally.** `targetSdk` comes from
`flutter.targetSdkVersion`, so a runner on an older Flutter silently produces
an artifact targeting a lower API level than the one you verified — and Play
enforces a minimum target API level. Re-run the `aapt2` check in §5a step 4
after any Flutter upgrade.

Two things to confirm against the build you are actually shipping, both
detailed in RELEASE-BACKGROUND.md:

- **Voice counting may report unavailable in a release build,** depending on
  whether the block-token client is wired in at this commit (`CLAUDE.md`,
  "Voice counting", has the mechanism). If it is, keep it out of the store
  listing copy and say so in the App Review notes. The `RECORD_AUDIO` and
  `NSMicrophoneUsageDescription` declarations stay either way.
- **Android voice sessions stop when the app is backgrounded.** Worth a line in
  the store description if voice is live.
