# Releasing Counta

How a Counta build gets from a clean checkout to users on Android and iOS.

This is the technical process — signing, versioning, build commands, CI,
cadence, rollback. It is written so that someone who forks this repository can
build and ship their own copy of the app from it.

Everything specific to *this* app's store listings lives outside the
repository. If you are the owner and you are looking for the Play Console
first-submission walkthrough, it is in `docs/play-submission.internal.md`,
which is gitignored on purpose.

---

## 1. Versioning

One line in `pubspec.yaml` is the source of truth for both platforms:

```yaml
version: 0.2.0+1
#        ^^^^^ ^
#        │     └── build number   (n)
#        └──────── version name   (x.y.z)
```

Flutter maps it like this:

| pubspec | Android | iOS |
| --- | --- | --- |
| `x.y.z` (before the `+`) | `versionName` | `CFBundleShortVersionString` |
| `n` (after the `+`) | `versionCode` | `CFBundleVersion` |

Nothing in the project hardcodes either value. `android/app/build.gradle.kts`
reads `flutter.versionCode` / `flutter.versionName`, and `ios/Runner/Info.plist`
reads `$(FLUTTER_BUILD_NAME)` / `$(FLUTTER_BUILD_NUMBER)`. The iOS Live Activity
extension picks the same values up through `ios/Flutter/AppIdentity.xcconfig`,
which includes `Generated.xcconfig` precisely so the appex version never drifts
from the app's.

You can override either at build time with `--build-name` / `--build-number`
without editing `pubspec.yaml`.

### The one rule you cannot break

**The build number must strictly increase on every upload to either store, and
can never be reused or lowered.**

Not per release — per *upload*. If you upload `0.3.0+7` and then find a bug
before you promote it, the replacement is `0.3.0+8`, not another `+7`. Google
Play rejects a duplicate `versionCode` outright. App Store Connect rejects a
`CFBundleVersion` that is not higher than the last build of the same
`CFBundleShortVersionString`. Both stores count the number *forever*, including
builds you deleted, expired, or never released.

The two stores keep separate counters, but keeping one shared number across
both is far easier to reason about than two, so treat the number in
`pubspec.yaml` as global.

The version name has no such rule — you can ship `1.2.0` after `1.10.0` if you
insist — but semver applies here as everywhere: `x` for a breaking change to
saved data or behaviour, `y` for a user-visible feature, `z` for fixes.

### How `version-bump.yml` fits in

`.github/workflows/version-bump.yml` is a manual `workflow_dispatch`. You pick
`patch` / `minor` / `major`; it rewrites the `version:` line in `pubspec.yaml`,
increments the build number by one, commits, and pushes a `vX.Y.Z` tag. That
tag is what triggers `.github/workflows/release.yml`.

Two things to know before you rely on it:

- It needs a `RELEASE_PAT` repository secret (a personal access token with
  `contents: write`). The default `GITHUB_TOKEN` will not do, because a push
  made with it does not trigger other workflows, so the tag would land and
  `release.yml` would never fire.
- **It bumps the build number once per version bump, not once per upload.** It
  is the right tool for starting a release; it is the wrong tool for replacing
  a build you already uploaded. For that, either edit the `+n` in
  `pubspec.yaml` by hand or pass `--build-number` on the build command.

---

## 2. Cadence

A cadence only helps if it is small enough to actually keep. These are the
numbers to follow; the reasoning is underneath each one.

| Kind of release | Trigger | Soak before promotion | Rollout |
| --- | --- | --- | --- |
| **Hotfix** (`z`) | A crash or data-loss bug confirmed in production | 12–24 h internal only | Straight to 100 %; the bug is worse than the risk |
| **Fix roll-up** (`z`) | 2+ user-visible fixes, or 4 weeks since the last release | 3 days internal | 20 % → 50 % → 100 %, one day each |
| **Feature** (`y`) | A feature a user would notice and you would write a release note about | 3 days internal, then 7 days closed testing | 10 % → 25 % → 50 % → 100 % |
| **Major** (`x`) | Breaking change to the Hive schema or to how sessions are counted | 3 days internal, then 14 days closed testing | 5 % → 10 % → 25 % → 50 % → 100 %, two days each |

**Ship at most one feature release a month, and never more than one release a
week of any kind.** Every upload is irreversible, every one starts a review
clock on iOS, and a solo developer who ships weekly spends the whole month
watching rollouts instead of building.

**Refactors, test additions, CI changes and documentation do not justify a
release.** They ride along with the next one. The test for "does this justify a
release" is whether you can write a one-line changelog entry that a user would
care about. If you cannot, it is not a release.

**Why the soak periods.** Internal testing on Play reaches your own devices in
minutes, so three days is enough to catch anything that only appears on a real
device: a permission prompt that does not fire, a Live Activity that never
ends, a voice session that dies on backgrounding. Closed testing exists to find
what your own two devices cannot — OEM audio-stack differences, unusual
locales, older Android versions. Seven days is roughly the minimum for a small
tester group to produce a session on each of their devices; two weeks is what a
schema change deserves, because a migration bug that corrupts saved sessions
cannot be fixed forward.

**Why staged percentages.** Play reports crash-free rate per release. At 10 %
you have enough sessions within a day to see a regression, and 90 % of users
never receive the bad build. Going straight to 50 % halves that protection for
no gain — the build does not get better by reaching more people faster.

**Halt thresholds.** Stop the rollout and do not advance if any of these is
true at the current percentage:

- crash-free sessions below **99.0 %**, or more than 0.5 pp below the previous
  release;
- ANR rate above **0.47 %** — Play's own "bad behaviour" threshold, above which
  it will start demoting the app in search;
- any single new crash cluster affecting more than **0.5 %** of sessions;
- more than a couple of reviews describing the same new problem.

---

## 3. Android release signing

### Play App Signing — read this before you make a key

Google Play holds **two** keys for your app, and confusing them is the single
most expensive mistake a first-time publisher makes.

- The **app signing key** signs the APKs that Google generates from your bundle
  and delivers to devices. Under Play App Signing, **Google holds this key**.
  You never see it. It is what Android uses to decide that an update is really
  an update of the same app, so if it were ever lost the app could never be
  updated again by anyone.
- The **upload key** is yours. It signs the AAB you upload. Google verifies the
  signature, strips it, and re-signs with the app signing key. It proves an
  upload came from you and does nothing else.

**This is why the split matters: if you lose your upload key, you are not
finished.** You generate a new one and ask Play support to register it, and
your existing users keep getting updates, because the app signing key — the one
that actually matters to devices — never left Google. Before Play App Signing,
losing your keystore meant publishing a new app under a new package name and
abandoning your install base.

Play App Signing is mandatory for apps created after August 2021, so it is on
for this app whether or not you think about it. The practical consequences:

- Still back the upload keystore and its passwords up properly. Recovery
  through support is real but it is a support ticket with a wait, not a click.
- The SHA-1 / SHA-256 fingerprints that third-party services want (Google
  Sign-In, Maps, deep-link verification) are the **app signing key's**
  fingerprints, which you copy from Play Console › Setup › App integrity — not
  your upload key's. A build that works locally and fails from the store is
  almost always this.
- Enrol in Play App Signing when you create the app and let Google generate the
  app signing key. Do not upload one you generated yourself; there is no reason
  to hold a copy of a key whose only job is to be held by Google.

### Configuring the upload key locally

Create the key once:

```bash
keytool -genkey -v \
  -keystore ~/counta-upload-key.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias counta-upload
```

`-validity 10000` is about 27 years. Play requires the key to outlive
2033-10-22, so do not shorten it.

Then:

```bash
cp android/key.properties.example android/key.properties
# fill in storeFile, storePassword, keyAlias, keyPassword
```

`android/app/build.gradle.kts` reads that file. Both it and any `*.jks` /
`*.keystore` are gitignored — this is a public repository and a committed
upload key cannot be un-published. Verify at any time with:

```bash
git check-ignore -v android/key.properties android/upload-keystore.jks
```

### What happens when the file is absent

Deliberately, not an error. A contributor with no keystore can still run
`flutter run --release` and `make build-android`; the release build type falls
back to the debug signing config and Gradle prints a warning saying so.

Store-bound builds refuse that fallback. `make build-appbundle` sets
`ORG_GRADLE_PROJECT_requireReleaseSigning=true`, and the build fails at
configuration time with instructions rather than producing a debug-signed AAB
that Play rejects an hour later.

Check what actually signed an artifact:

```bash
$ANDROID_HOME/build-tools/<ver>/apksigner verify --print-certs \
  build/app/outputs/flutter-apk/app-release.apk
```

`CN=Android Debug` means the fallback was taken.

---

## 4. Build commands

| Command | Produces | For |
| --- | --- | --- |
| `make build-appbundle` (or `make appbundle`) | `build/app/outputs/bundle/release/app-release.aab` | Google Play. Requires the upload key. |
| `make build-android` | `build/app/outputs/flutter-apk/app-release.apk` | Direct download, the GitHub release, sideloading. |
| `make build-ios-ipa` | `build/ios/archive/Runner.xcarchive` | App Store Connect / TestFlight. |
| `make release-preflight` | nothing | The gate before you tag. |

### Compile-time configuration

Dev and store builds do not take the same defines, and the difference is a
security boundary rather than a convenience.

`DART_DEFINES` (used by `make run`, `make build-android`, `make build-web`)
forwards the whole `.env` file when there is one. `RELEASE_DART_DEFINES` (used
by `make build-appbundle` and `make build-ios-ipa`) forwards only
`SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`.

The reason is `DEEPGRAM_API_KEY`. `lib/core/config/dev_secrets.dart` is the
only reader, and it throws unless `BuildConfig.showDebugTools` is on — which is
a compile-time constant, so in release the *read* is dead code. The *define* is
not. Flutter embeds every `--dart-define` in the artifact, so a release build
made with `--dart-define-from-file=.env` ships the Deepgram master key to
anyone who unzips the AAB. Never point a store build at `.env`.

Both Supabase values are public client configuration and are safe to embed. A
build without them is valid; it simply has no backend, which today changes
nothing observable (see Known limitations).

---

## 5. Preflight checklist

Run before every tag. `make release-preflight` does the first four.

- [ ] `git status` is clean and you are on `main`, up to date with `origin`.
- [ ] `make test` passes.
- [ ] `make lint` passes. Eight `deprecated_member_use` infos about `Radio` in
      `settings_screen.dart` and `sound_mode_sheet.dart` are known and expected;
      anything else is not.
- [ ] `make test-corpus` passes — the transcript fixture recall gates in
      `test/fixtures/corpus_test.dart`. This is the only automated check on
      counting accuracy; a regression here ships a counter that miscounts.
- [ ] `pubspec.yaml` build number is higher than anything you have ever
      uploaded to either store.
- [ ] `CHANGELOG.md` has an entry for this version.
- [ ] **Android permission strings.** `android/app/src/main/AndroidManifest.xml`
      declares `RECORD_AUDIO`, `POST_NOTIFICATIONS` and `INTERNET`. The merged
      manifest additionally pulls in `VIBRATE`, `WAKE_LOCK`,
      `ACCESS_NETWORK_STATE` and `com.google.android.c2dm.permission.RECEIVE`
      from plugins. Confirm the merged set with:
      `aapt2 dump badging <apk> | grep uses-permission`, and confirm every
      entry is reflected in your Play data safety declaration.
- [ ] **iOS permission strings.** `ios/Runner/Info.plist` must still contain a
      non-empty `NSMicrophoneUsageDescription`, and `UIBackgroundModes`
      containing `audio`. App Review rejects a missing or generic usage string,
      and dropping the background mode silently kills long voice sessions.
- [ ] Store metadata that changed this release (screenshots, description,
      what's-new text) is ready in both consoles.
- [ ] You have read §7 (Known limitations) and none of them became worse.

---

## 6. Run books

### 6a. Android

From a clean checkout to a live staged rollout.

1. **Preflight.** `git checkout main && git pull && make release-preflight`.
   Fix anything red before continuing. Do not proceed with a dirty tree.
2. **Bump the version.** Either run the *Version Bump* workflow in the Actions
   tab (choose patch/minor/major — it commits, tags and pushes), or edit
   `version:` in `pubspec.yaml` by hand and tag yourself. Confirm the build
   number is higher than every previous upload.
3. **Build the bundle.**
   ```bash
   make build-appbundle
   ```
   It fails immediately if `android/key.properties` is missing. On success the
   AAB is at `build/app/outputs/bundle/release/app-release.aab`.
4. **Sanity-check the artifact** before uploading. From the APK of the same
   commit (`make build-android`):
   ```bash
   aapt2 dump badging build/app/outputs/flutter-apk/app-release.apk \
     | grep -E "^package:|targetSdkVersion"
   ```
   Confirm `versionCode`, `versionName` and `targetSdkVersion` are what you
   expect. Confirm `apksigner --print-certs` does **not** say
   `CN=Android Debug`.
5. **Upload to internal testing.** Play Console › your app › Testing ›
   Internal testing › Create new release › upload the AAB › add release notes ›
   Save › Review release › Start rollout to Internal testing. It reaches
   testers within minutes.
6. **Test it on a real device from the store install**, not from `flutter run`.
   Install through the internal-testing opt-in link. Walk the paths that only
   break in release: first launch with no saved data, granting and denying the
   microphone permission, a voice session (see Known limitations — expect it to
   report unavailable today), a long tap session backgrounded and resumed, the
   Live Activity ending when the session ends, and a session saved and reloaded
   after a cold start.
7. **Soak** for the period in §2 for this kind of release.
8. **Promote to closed testing.** Internal testing › the release › Promote
   release › Closed testing. Same artifact, no rebuild — promotion moves the
   build you already tested, which is the entire point of tracks.
9. **Promote to production with a staged rollout.** Promote again to
   Production, and set the rollout percentage rather than accepting 100 %. Use
   the ladder from §2 for this release kind.
10. **Watch, then advance.** Play Console › Quality › Android vitals, filtered
    to the new version. Advance one step at a time with at least 24 h between
    steps, checking the §2 halt thresholds each time. Reviews arrive later than
    vitals, so check both.
11. **Reach 100 %,** then update `CHANGELOG.md` if the workflow did not, and
    confirm the GitHub release created by `release.yml` has the artifacts you
    expect.

**Halting a rollout.** Play Console › Production › the release › **Halt
rollout**. Users who already received the build keep it — halting stops further
distribution, it does not claw anything back. Do this the moment a halt
threshold trips; you can always resume, and resuming is cheap while a bad build
spreading is not.

### 6b. iOS

1. **Preflight.** Same as Android, plus: the signing certificate and
   provisioning profile in Xcode are valid and not about to expire, and the
   `CountaLiveActivityExtension` target's identifier still resolves to
   `$(APP_BUNDLE_ID).CountaLiveActivity`. iOS refuses to install an app whose
   appex identifier is not prefixed by the host app's, and it fails at install
   time, not build time.
2. **Confirm the release configuration is the one being archived.**
   `ios/Flutter/AppIdentity.xcconfig` gives Debug and Profile the `.dev` bundle
   id and Release the published one. An archive built from a Debug
   configuration uploads under the wrong identifier.
3. **Archive.**
   ```bash
   make build-ios-ipa
   ```
   Then `open build/ios/archive/Runner.xcarchive`, or archive from Xcode
   directly (Product › Archive) if you want the Organizer's validation step.
4. **Upload to App Store Connect** from Xcode Organizer › Distribute App › App
   Store Connect › Upload. Processing takes 5–60 minutes; you get an email when
   the build is available, and often a second email listing warnings.
5. **TestFlight internal.** App Store Connect › TestFlight › Internal Testing.
   Up to 100 members of your team, available as soon as processing finishes,
   **no review required**. Test here first, always.
6. **Export compliance.** The first upload of each version asks whether the app
   uses encryption. Counta uses HTTPS/WSS only, which is exempt, but you must
   still answer. Answering it once per version in App Store Connect — or adding
   `ITSAppUsesNonExemptEncryption=false` to `Info.plist` — stops it blocking
   every build.
7. **TestFlight external** (optional but recommended for a feature release).
   External groups take up to 10 000 testers and **require a Beta App Review**
   on the first build of each version — usually under 24 h, but budget a day.
   Subsequent builds of the same version normally skip it.
8. **Submit for review.** App Store Connect › your app › the version ›
   Add for Review. Review is typically 24–48 h; assume longer near Apple's
   holiday shutdown in late December.
9. **Phased release.** In the version's Release options choose *Release update
   over 7 days using phased release*. Apple's schedule is fixed: 1 %, 2 %, 5 %,
   10 %, 20 %, 50 %, 100 % on days 1–7. You can pause it, and users can always
   update manually. Phased release applies to *updates* only — a first release
   goes to everyone at once.

**What bites first-time iOS submitters**

- **Permission usage strings.** `NSMicrophoneUsageDescription` must say
  specifically what the app does with the microphone and why the user benefits.
  "This app needs microphone access" is rejected. The string already in
  `Info.plist` is the right shape — keep that level of specificity.
- **Background audio.** `UIBackgroundModes: audio` gets scrutiny. Reviewers
  check that the app has an audible, user-visible reason to hold the audio
  session in the background. Be ready to explain in the review notes that
  sessions run 1–2 hours and must keep counting while the screen is off, and
  make sure a reviewer can actually observe that behaviour.
- **A demo account and review notes.** If any feature is gated, give the
  reviewer working credentials and step-by-step instructions in App Review
  Information. Half of first rejections are "we could not access the feature".
- **In-app purchases ship *with* an app version, not separately.** The first
  IAP you ever create must be submitted attached to an app version — you cannot
  approve products on their own and then reference them from a later build.
  Every product also needs a **review screenshot** of the purchase UI as the
  user sees it, at real device resolution, plus a review note explaining what
  the product does. A missing screenshot fails the product, and a failed
  product blocks the whole version. Counta has no IAP wired in today (nothing
  in `pubspec.yaml` provides one), so this bites on the first monetised
  release, not this one — plan two extra days for it.
- **Privacy nutrition labels** are separate from the Android data safety form
  and must agree with it. Both must match what the app actually does, which for
  Counta means: audio is collected during a session, sent to a third-party
  processor, and not stored.

---

## 7. Rollback

**Be honest about this: you cannot un-ship a build.** Neither store will remove
an app version from devices that already installed it. Everything below limits
the blast radius or moves forward; nothing undoes.

In order, fastest first:

1. **Halt the staged rollout** (Play: Production › Halt rollout. iOS: pause the
   phased release). Seconds to take effect, stops the build reaching anyone
   new. This is the only reason staged rollouts are worth the extra days —
   always do this before you diagnose.
2. **Android only: roll back to a previous artifact.** Play lets you create a
   new production release containing a previously uploaded bundle. Two
   constraints that catch people out:
   - it needs a **new, higher `versionCode`**, so upload the old *code* rebuilt
     with a bumped build number — you cannot literally re-release the old AAB;
   - a user who already installed the bad version will **not** be downgraded.
     Android will not install a lower `versionName` over a higher one. They
     stay broken until you ship forward.
   So this protects people who have not updated yet. It does not rescue anyone
   who has.
3. **Ship a fix forward.** For everyone already on the bad build this is the
   only real remedy. Hotfix cadence: patch bump, 12–24 h internal soak, then
   straight to 100 % — the bug is worse than the rollout risk. On iOS request
   **expedited review** (App Store Connect › Contact Us › App Review ›
   Expedited Review Request) and describe the user impact concretely. Apple
   grants these for genuine crash-level bugs and remembers if you cry wolf.
4. **iOS only: remove the version from sale** as a last resort. This stops new
   downloads entirely, including the working previous version, and existing
   users keep the broken build. Almost never the right call.

**The implication for cadence.** Because there is no undo, the value of the
staged rollout is entirely front-loaded — the 10 % day is where you can still
act. Do not treat the percentages as a formality to click through.

---

## 8. CI

### `release.yml`

Triggered by pushing a `v*.*.*` tag (or `workflow_dispatch` with a tag input).
It creates a GitHub release and attaches an Android APK, a macOS `.dmg`, and a
Windows `.zip`.

It also builds a **signed AAB when the signing secrets are present**, and skips
that job cleanly when they are not, so forks and pull requests still build.
The workflow never uploads to any store; it only attaches artifacts to the
GitHub release.

To enable the signed AAB job, create these four repository secrets
(Settings › Secrets and variables › Actions):

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | The upload keystore, base64-encoded (below) |
| `ANDROID_KEYSTORE_PASSWORD` | `storePassword` from `key.properties` |
| `ANDROID_KEY_ALIAS` | `keyAlias` |
| `ANDROID_KEY_PASSWORD` | `keyPassword` |

All four must be present or the job skips. Two more are optional and forwarded
as `--dart-define`s when set: `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`.
Both are public client configuration. `DEEPGRAM_API_KEY` is deliberately not
among them — see §4.

Encode the keystore:

```bash
base64 -i ~/counta-upload-key.jks | pbcopy   # macOS
base64 -w0 ~/counta-upload-key.jks           # Linux
```

Paste the result as the secret value with no line breaks. The workflow decodes
it into `android/upload-keystore.jks`, writes an `android/key.properties`
pointing at it, builds, and deletes both in an `always()` cleanup step. Secrets
are not exposed to workflows triggered from forked pull requests, which is what
makes the "skip cleanly" behaviour work by itself.

The resulting AAB is attached to the GitHub release. **Uploading it to Play is
a manual step, on purpose** — nothing in this repository has credentials to
publish to a store.

Three known rough edges, none blocking:

- **The APK attached to the GitHub release is debug-signed.** The `build-android`
  job runs plain `flutter build apk --release` with no keystore, so it takes the
  fallback. That is fine for a sideload but means every release's APK may carry
  a different signature, and Android refuses to install an update signed by a
  different key — a user who downloaded a previous APK must uninstall first.
  Signing it with the upload key would fix that, but it is a distinct decision
  from Play signing and would change the signature once, breaking upgrades for
  anyone already on a debug-signed build. Decide before there are users on the
  GitHub APK; it costs nothing now and cannot be undone cleanly later.


- The workflow pins `flutter-version: '3.44.8'`. Keep it equal to the version
  you build with locally. `targetSdk` comes from `flutter.targetSdkVersion`, so
  a CI runner on an older Flutter would silently produce an artifact targeting
  a lower API level than your local build — and Play enforces a minimum target
  API level.
- It uses `actions/create-release@v1` and `actions/upload-release-asset@v1`,
  both archived by GitHub. They still work. When they stop, replace both with
  `softprops/action-gh-release` or `gh release create`.

### `version-bump.yml`

See §1. Manual dispatch, needs `RELEASE_PAT`.

---

## 9. Known limitations for this release

Verified against the code at the commit that added this document. Read this
before writing release notes or answering a store questionnaire.

### Voice counting reports unavailable in a release build

**A release build today ships tap counting only.** This is the largest gap
between what the repository describes and what a user would get.

`lib/core/config/build_config.dart` defines `showDebugTools` as
`kDebugMode || kProfileMode` — a compile-time constant, false in release.
`deepgramTokenProviderProvider` in `lib/state/providers/counter_provider.dart`
throws `VoiceUnavailable` whenever that flag is false:

> "Voice counting needs a block token from the voice-block service, which is
> not wired into this build yet."

`CloudCountingEngine` turns that into `EngineStatus.notConfigured` and the UI
shows the message, so it fails visibly rather than silently — but it fails. The
compiled-in Deepgram key was deliberately removed, and the block client that is
meant to replace it (fetching a short-lived token from the `voice-block`
Supabase Edge Function under `supabase/`) is still in progress. The Edge
Function itself exists and has tests; nothing in `lib/` calls it yet.

Consequences:

- Do not describe voice counting in store listing copy for this release.
- The `RECORD_AUDIO` / `NSMicrophoneUsageDescription` declarations are still
  correct and must stay — the feature is present and gated, not removed — but
  an App Review reviewer who tries voice counting will see it report
  unavailable. Say so in the review notes rather than letting them find it.
- Supabase defines are therefore optional for this release. They become
  required the moment the block client lands.

### Android voice sessions stop when the app is backgrounded

True, but **the reason recorded in `CLAUDE.md` is wrong**, and the correction
changes what fixing it costs.

`CLAUDE.md` says Android background recording "needs a foreground service,
which `record_android` does not provide". `record_android` 1.5.2 *does* provide
one: `AudioRecordingService` (a real `Service` calling `startForeground`), wired
to the `AndroidRecordConfig.service` option in `record_platform_interface`
1.6.0. It is simply not switched on here.

What is actually missing:

- `AudioSource.recordConfig` (`lib/core/services/counting/audio_source.dart`)
  passes `iosConfig` only. With no `androidConfig`, `AndroidRecordConfig`
  defaults to `service: null`, and `RecorderWrapper.startService` returns
  without doing anything.
- `android/app/src/main/AndroidManifest.xml` declares no `<service>` element
  and neither `FOREGROUND_SERVICE` nor `FOREGROUND_SERVICE_MICROPHONE`.

So an Android voice session runs only while the app is foregrounded. iOS is
unaffected — it uses `UIBackgroundModes: audio`, which is declared and working.

Two caveats before anyone reaches for the plugin's service:

- The option is `@Deprecated("Prefer external package usage. Will be removed in
  next major version.")` as of `record_platform_interface` 1.6.0.
- `AudioRecordingService.onStartCommand` calls `startForeground(id,
  notification)` with no `foregroundServiceType`. Android 14 (API 34) requires a
  microphone foreground service to declare
  `android:foregroundServiceType="microphone"` and hold
  `FOREGROUND_SERVICE_MICROPHONE`, and this app targets API 36. The plugin's
  built-in service is very likely insufficient on its own for a modern target.

A proper fix is a dedicated foreground service with the right type and
permission, not a config flag. Until then this limitation stands and is worth a
line in the store description, because "counting stops when you leave the app"
is exactly the kind of surprise that earns one-star reviews. It has no user
impact *this* release, because voice counting is unavailable in release anyway.

### Debug builds share the release `applicationId` on Android

On iOS, `ios/Flutter/AppIdentity.xcconfig` gives Debug and Profile builds
`com.ruach-tech.counta.dev`, so a dev build installs alongside the App Store
version. Android has no equivalent: `android/app/build.gradle.kts` sets one
`applicationId = "com.ruachtech.counta"` with no `applicationIdSuffix`, so a
`flutter run` on Android **replaces the Play build on that device**, taking its
Hive data with it.

Not a store blocker; a foot-gun for the owner, who is also a user of the app.
The fix is an `applicationIdSuffix = ".dev"` on the debug build type, which
would have to be done before the first Play release — after that, changing the
release `applicationId` is impossible, but adding a suffix to *debug* remains
safe at any time.

(The Android id has no hyphen and the iOS one does, because Android package
names cannot contain hyphens. That is intentional and both are permanent.)

### Target API level

`android/app/build.gradle.kts` sets `targetSdk = flutter.targetSdkVersion`,
which resolves from the Flutter SDK in use rather than being pinned here. On
Flutter 3.44.8 (`FlutterExtension.kt`) that is **36**, confirmed in a built
artifact:

```
$ aapt2 dump badging build/app/outputs/flutter-apk/app-release.apk
package: name='com.ruachtech.counta' versionCode='1' versionName='0.2.0' compileSdkVersion='36'
targetSdkVersion:'36'
```

Because the value follows the toolchain, **the CI Flutter version and your
local one must match** or the artifact CI produces may not target what you
verified. Re-run the `aapt2` check at preflight after any Flutter upgrade.

### Firebase Cloud Messaging is in the Android build without being asked for

`live_activities` 2.5.1 — used only for the **iOS** Live Activity — declares
`implementation 'com.google.firebase:firebase-messaging:24.0.0'`
unconditionally in its `android/build.gradle`. So the Android artifact carries
the FCM SDK, a `FirebaseInstanceIdReceiver`, and
`com.google.android.c2dm.permission.RECEIVE` in the merged manifest:

```
$ grep uses-permission build/app/intermediates/merged_manifests/release/*/AndroidManifest.xml
  POST_NOTIFICATIONS  RECORD_AUDIO  INTERNET  VIBRATE
  ACCESS_NETWORK_STATE  WAKE_LOCK  com.google.android.c2dm.permission.RECEIVE
```

There is no `google-services.json` in the repository, so FCM has no project
configuration and never registers a token — it collects nothing at runtime. But
it is visible to anyone who inspects the APK, and a store reviewer is entitled
to ask why a counting app receives push messages. Either be ready to explain
it, or exclude the dependency:

```kotlin
// android/app/build.gradle.kts
configurations.all {
    exclude(group = "com.google.firebase", module = "firebase-messaging")
}
```

Test an Android build afterwards if you do. Not done here because it changes
runtime behaviour and this change set is build configuration only.

`ACCESS_ADVERTISING_ID` is **not** present in the merged manifest — worth
knowing when a store questionnaire asks.

### No in-app purchases

Nothing in `pubspec.yaml` provides IAP. The block/credit model in
`specs/voice-phrase-counting/` is designed but not implemented, so nothing in
this release needs store products, tax details, or the IAP review path in §6b.

---

## 10. What this repository will never do

No workflow, script, or Makefile target here uploads to Google Play or the App
Store, promotes a track, or publishes a release. Every artifact stops at the
GitHub release, and a human moves it to a store console. Adding automated
publishing means putting store credentials in a public repository's secrets,
and the failure mode is an accidental production rollout from a mistyped tag.
