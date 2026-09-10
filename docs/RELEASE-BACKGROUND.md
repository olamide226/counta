# Release background

Why the release process in [RELEASING.md](RELEASING.md) is shaped the way it
is. Nothing here is needed to ship a build. Read it once, or when a decision in
the run book stops making sense.

---

## Cadence, and why the numbers are what they are

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

**Why the staged rollout is worth the extra days.** Because there is no undo
(see Rollback in the run book), the value is entirely front-loaded: the 10 %
day is the only point where you can still act. The percentages are not a
formality to click through.

---

## Play App Signing

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

---

## Android release signing

Release builds are signed with the **upload key**, not the key that signs what
users install — Google holds that one. If you have not met that distinction,
read Play App Signing above before making a key.

Create the key once:

```bash
keytool -genkey -v \
  -keystore ~/counta-upload-key.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias counta-upload
```

`-validity 10000` is about 27 years. Play requires the key to outlive
2033-10-22, so do not shorten it. Then:

```bash
cp android/key.properties.example android/key.properties
# fill in storeFile, storePassword, keyAlias, keyPassword — all four
```

`android/key.properties` and any `*.jks` / `*.keystore` are gitignored by
`android/.gitignore`; this is a public repository and a committed upload key
cannot be un-published. Verify any time with:

```bash
git check-ignore -v android/key.properties android/upload-keystore.jks
```

What happens when the file is missing or half-filled, and how to check which
key signed an artifact, is in RELEASING.md §2.

---

## CI signing secrets

`release.yml` builds the signed AAB only when all four of these repository
secrets exist (Settings › Secrets and variables › Actions). Any missing one
skips the AAB steps and still produces the APK.

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | The upload keystore, base64-encoded (below) |
| `ANDROID_KEYSTORE_PASSWORD` | `storePassword` from `key.properties` |
| `ANDROID_KEY_ALIAS` | `keyAlias` |
| `ANDROID_KEY_PASSWORD` | `keyPassword` |

Two more are optional and forwarded as `--dart-define`s when set:
`SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`. Both are public client
configuration. `DEEPGRAM_API_KEY` is deliberately not among them — see
"Compile-time configuration" in the run book.

Encode the keystore:

```bash
base64 -i ~/counta-upload-key.jks | pbcopy   # macOS
base64 -w0 ~/counta-upload-key.jks           # Linux
```

Paste the result as the secret value with no line breaks. The workflow decodes
it into `android/upload-keystore.jks`, writes an `android/key.properties`
pointing at it, builds through `make build-appbundle`, and deletes both in an
`always()` cleanup step.

### Rough edges in `release.yml`

- **The APK attached to the GitHub release is debug-signed.** The build takes
  the debug fallback because the keystore is only written for the AAB steps.
  That is fine for a sideload but means every release's APK may carry a
  different signature, and Android refuses to install an update signed by a
  different key — a user who downloaded a previous APK must uninstall first.
  Signing it with the upload key would fix that, but it is a distinct decision
  from Play signing and would change the signature once, breaking upgrades for
  anyone already on a debug-signed build. Decide before there are users on the
  GitHub APK; it costs nothing now and cannot be undone cleanly later.
- It uses `actions/create-release@v1` and `actions/upload-release-asset@v1`,
  both archived by GitHub. They still work. When they stop, replace both with
  `softprops/action-gh-release` or `gh release create`.

---

## What first iOS rejections are about

- **Usage strings.** `NSMicrophoneUsageDescription` must say specifically what
  the app does with the microphone and why the user benefits. "This app needs
  microphone access" is rejected. The string in `Info.plist` is the right
  shape — keep that level of specificity.
- **Background audio.** `UIBackgroundModes: audio` gets scrutiny. Reviewers
  check that the app has an audible, user-visible reason to hold the audio
  session in the background. Be ready to explain in the review notes that
  sessions run 1–2 hours and must keep counting with the screen off, and make
  sure a reviewer can actually observe that behaviour.
- **A demo account and review notes** for anything gated. Give working
  credentials and step-by-step instructions in App Review Information; half of
  first rejections are "we could not access the feature".
- **Privacy nutrition labels** are separate from the Android data safety form
  and must agree with it. For Counta: audio is collected during a session, sent
  to a third-party processor, and not stored.

---

## Known limitations, in detail

Verified against the code at the commit that added this document.

### Android voice sessions stop when the app is backgrounded

`record_android` 1.5.2 *does* ship a foreground service —
`AudioRecordingService.kt:15` is a real `Service`, and `RecorderWrapper.kt:148`
starts it — so "the plugin does not provide one" is not the reason. Three
things are actually missing or in the way:

- **The config is never passed.** `AudioSource.recordConfig`
  (`lib/core/services/counting/audio_source.dart:76`) sets `iosConfig` only.
  With no `androidConfig`, `AndroidRecordConfig.service` defaults to null and
  `RecorderWrapper.startService` returns without doing anything.
- **The manifest declares nothing.** `android/app/src/main/AndroidManifest.xml`
  has no `<service>` element and neither `FOREGROUND_SERVICE` nor
  `FOREGROUND_SERVICE_MICROPHONE`. The plugin's own manifest declares only
  `RECORD_AUDIO`, so the merge adds nothing.
- **The upstream option is deprecated and probably insufficient anyway.**
  `AndroidRecordConfig.service` is `@Deprecated("Prefer external package usage.
  Will be removed in next major version.")` as of `record_platform_interface`
  1.6.0, and `AudioRecordingService.kt:56` calls `startForeground(id,
  notification)` with no `foregroundServiceType`. Android 14 (API 34) requires
  a microphone foreground service to declare
  `android:foregroundServiceType="microphone"` and hold
  `FOREGROUND_SERVICE_MICROPHONE`, and this app targets 36.

A proper fix is a dedicated foreground service with the right type and
permission, not a config flag. iOS is unaffected — it uses
`UIBackgroundModes: audio`, which is declared and working.

> **`CLAUDE.md` currently records the wrong reason** for this ("needs a
> foreground service, which `record_android` does not provide"). Correcting it
> is a one-line edit to that file, deliberately left to the repository owner.

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

### Firebase Cloud Messaging is in the Android build without being asked for

`live_activities` 2.5.1 — used only for the **iOS** Live Activity — declares
`implementation 'com.google.firebase:firebase-messaging:24.0.0'`
unconditionally in its `android/build.gradle`. So the Android artifact carries
the FCM SDK, a `FirebaseInstanceIdReceiver`, and
`com.google.android.c2dm.permission.RECEIVE` in the merged manifest.

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

Test an Android build afterwards if you do.

`ACCESS_ADVERTISING_ID` is **not** present in the merged manifest — worth
knowing when a store questionnaire asks.

### No in-app purchases

Nothing in `pubspec.yaml` provides IAP, and the block/credit model in
`specs/voice-phrase-counting/` is designed but not implemented. So nothing in
this release needs store products or tax details.

It is worth knowing what the first monetised release will cost, because it is
not obvious: **on iOS, in-app purchases ship *with* an app version, not
separately.** The first IAP you ever create must be submitted attached to an
app version — you cannot approve products on their own and reference them from
a later build. Every product also needs a review screenshot of the purchase UI
at real device resolution, plus a review note explaining what it does. A
missing screenshot fails the product, and a failed product blocks the whole
version. Budget two extra days for that release.

---

## What this repository will never do

No workflow, script, or Makefile target here uploads to Google Play or the App
Store, promotes a track, or publishes a release. Every artifact stops at the
GitHub release, and a human moves it to a store console. Adding automated
publishing means putting store credentials in a public repository's secrets,
and the failure mode is an accidental production rollout from a mistyped tag.
