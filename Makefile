.PHONY: help setup format lint analyze test test-corpus test-coverage build-runner clean build-ios build-ios-ipa build-android build-appbundle release-preflight build-macos build-web run run-ios run-android run-web doctor icons pull-fixtures supabase-start supabase-stop supabase-test supabase-serve supabase-linked supabase-status supabase-preflight supabase-deploy supabase-secrets supabase-smoke

# Environment Configuration
# Automatically loads variables from .env file if present, or CLI overrides.
-include .env

# Every key the app reads with String.fromEnvironment. Add one here and both
# the .env path and the command-line path pick it up.
DART_DEFINE_KEYS := DEEPGRAM_API_KEY SUPABASE_URL SUPABASE_PUBLISHABLE_KEY

# $(call dart_defines,KEY...) -> --dart-define=KEY=<value> for each key that has
# a value. Values come from .env (via `-include` above), the command line, or
# the environment — make treats all three as variables, which is what lets CI
# call these targets with the secrets exported as step `env`.
dart_defines = $(foreach key,$1,$(if $($(key)),--dart-define=$(key)=$($(key))))

# With a .env every key in it becomes a dart-define. Without one, forward
# whichever of the known keys were passed on the command line.
DART_DEFINES := $(if $(wildcard .env),--dart-define-from-file=.env,\
	$(call dart_defines,$(DART_DEFINE_KEYS)))

# Store-bound and published builds get everything except the Deepgram key.
#
# --dart-define-from-file=.env would forward DEEPGRAM_API_KEY too. Dart's
# compile-time gate makes the *read* dead code in release (BuildConfig.
# showDebugTools is a const false), but the define itself is still embedded in
# the artifact, so a .env-driven release build would ship the master key to
# anyone who unzips the AAB. Release builds therefore name their keys.
#
# The exclusion below is the only place that rule is written down.
RELEASE_DART_DEFINES := \
	$(call dart_defines,$(filter-out DEEPGRAM_API_KEY,$(DART_DEFINE_KEYS)))


# Default target
help:
	@echo "Counta - Mantra Counter App"
	@echo ""
	@echo "Available commands:"
	@echo "  make setup          - Install dependencies and generate code"
	@echo "  make format         - Format all Dart code"
	@echo "  make lint           - Run linter (dart analyze)"
	@echo "  make analyze        - Run static analysis"
	@echo "  make test           - Run all unit tests"
	@echo "  make test-corpus    - Evaluate transcript fixture corpus recall gates"
	@echo "  make test-coverage  - Run tests with coverage report"
	@echo "  make build-runner   - Generate code for Hive models"
	@echo "  make clean          - Clean build artifacts"

	@echo ""
	@echo "Build and run commands read .env, or take any of $(DART_DEFINE_KEYS)"
	@echo "on the command line (e.g. make run DEEPGRAM_API_KEY=...)."
	@echo ""
	@echo "Build commands:"
	@echo "  make build-ios      - Build iOS app (debug/ad-hoc)"
	@echo "  make build-ios-ipa  - Build iOS archive for App Store/TestFlight"
	@echo "  make build-android  - Build Android APK (direct download / GitHub release)"
	@echo "  make build-appbundle- Build Play-ready signed AAB (needs android/key.properties)"
	@echo "  make build-macos    - Build macOS app"
	@echo "  make build-web      - Build web app"
	@echo ""
	@echo "Run commands:"
	@echo "  make run            - Run app (default device)"
	@echo "  make run-ios        - Run on iOS"
	@echo "  make run-android    - Run on Android"
	@echo "  make run-web        - Run on Chrome"
	@echo ""
	@echo "Asset commands:"
	@echo "  make icons          - Generate app icons from assets/icon/app_icon.png"
	@echo ""
	@echo "Supabase commands (voice-block Edge Function):"
	@echo "  make supabase-start - Start the local Supabase stack and apply migrations"
	@echo "  make supabase-stop  - Stop the local Supabase stack"
	@echo "  make supabase-test  - Run the Edge Function Deno tests"
	@echo "  make supabase-serve - Serve Edge Functions locally (uses supabase/.env)"
	@echo "  make supabase-status  - Linked project: migrations, functions, secret names"
	@echo "  make supabase-deploy  - Preflight, apply migrations, deploy voice-block, smoke test"
	@echo "  make supabase-secrets - Push supabase/remote.env to the linked project's secrets"
	@echo "  make supabase-smoke   - Check the deployed function answers an anonymous call with 401"
	@echo ""
	@echo "Release commands (see docs/RELEASING.md):"
	@echo "  make release-preflight - Everything that must be green before a tag"
	@echo ""
	@echo "Other commands:"
	@echo "  make doctor         - Check Flutter environment"

# Setup project
setup:
	@echo "📦 Installing dependencies..."
	flutter pub get
	@echo "🔧 Generating Hive adapters..."
	dart run build_runner build --delete-conflicting-outputs
	@echo "✅ Setup complete!"

# Format code
format:
	@echo "🎨 Formatting Dart code..."
	dart format .
	@echo "✅ Formatting complete!"

# Lint code
lint:
	@echo "🔍 Running linter..."
	dart analyze
	@echo "✅ Linting complete!"

# Analyze code
analyze:
	@echo "🔍 Running static analysis..."
	flutter analyze
	@echo "✅ Analysis complete!"

# Run tests
test:
	@echo "🧪 Running tests..."
	flutter test
	@echo "✅ Tests complete!"

# Evaluate transcript fixture corpus recall gates
test-corpus:
	@echo "📊 Evaluating transcript corpus recall gates..."
	flutter test test/fixtures/corpus_test.dart


# Run tests with coverage
test-coverage:
	@echo "🧪 Running tests with coverage..."
	flutter test --coverage
	@echo "📊 Generating coverage report..."
	genhtml coverage/lcov.info -o coverage/html
	@echo "✅ Coverage report generated at coverage/html/index.html"

# Generate code (Hive adapters)
build-runner:
	@echo "🔧 Generating code..."
	dart run build_runner build --delete-conflicting-outputs
	@echo "✅ Code generation complete!"

# Watch and regenerate code on changes
build-runner-watch:
	@echo "👀 Watching for changes..."
	dart run build_runner watch --delete-conflicting-outputs

# Clean build artifacts
clean:
	@echo "🧹 Cleaning build artifacts..."
	flutter clean
	@echo "✅ Clean complete!"

# Build for iOS
build-ios:
	@echo "🍎 Building iOS app..."
	flutter build ios $(DART_DEFINES)
	@echo "✅ iOS build complete!"

# Build iOS archive (.ipa) for App Store / TestFlight.
# Store-bound, so it takes RELEASE_DART_DEFINES: no DEEPGRAM_API_KEY is
# embedded in an artifact that leaves this machine.
build-ios-ipa:
	@echo "🍎 Building iOS archive..."
	flutter build ipa --release $(RELEASE_DART_DEFINES)
	@echo "✅ iOS archive ready at build/ios/archive/Runner.xcarchive"
	@echo "   Upload via Xcode Organizer: open build/ios/archive/Runner.xcarchive"

# Build for Android (APK — direct download and the GitHub release, not Play)
#
# Takes RELEASE_DART_DEFINES for the same reason the store targets do: this is
# a release-mode artifact that gets published, and a .env-driven build would
# embed DEEPGRAM_API_KEY in something anyone can unzip. The key would be dead
# weight even if it were safe — BuildConfig.showDebugTools is a const false in
# release, so nothing reads it. Use `make run-android` for a dev build that
# can actually do voice.
build-android:
	@echo "🤖 Building Android APK..."
	flutter build apk $(RELEASE_DART_DEFINES)
	@echo "✅ Android build complete!"

# Play-ready Android App Bundle.
#
# Play requires an AAB for a new app; the APK above is for direct download.
# requireReleaseSigning makes android/app/build.gradle.kts fail loudly rather
# than fall back to the debug key, because a debug-signed AAB is only rejected
# once it reaches the Play Console.
build-appbundle:
	@echo "🤖 Building Play-ready Android App Bundle..."
	@test -n "$(SUPABASE_URL)" || echo "⚠️  SUPABASE_URL unset: this build has no backend config."
	ORG_GRADLE_PROJECT_requireReleaseSigning=true \
		flutter build appbundle --release $(RELEASE_DART_DEFINES)
	@echo "✅ AAB ready at build/app/outputs/bundle/release/app-release.aab"
	@echo "   Upload it to Play Console › Testing › Internal testing › Create new release."

# Everything that must be green before a tag. See docs/RELEASING.md.
#
# `test` runs the whole suite, which already collects
# test/fixtures/corpus_test.dart — the transcript recall gates are covered
# here. `test-corpus` stays a separate target for iterating on those gates
# alone; running it again from this chain would only cost time.
release-preflight: lint test
	@echo "🚦 Release preflight"
	@echo "--- version ---"
	@grep '^version:' pubspec.yaml
	@echo "--- flutter ---"
	@flutter --version | head -1
	@echo "--- signing ---"
	@test -f android/key.properties \
		&& echo "android/key.properties present (upload key configured)" \
		|| echo "⚠️  android/key.properties missing: make build-appbundle will fail."
	@echo "✅ Preflight complete. Re-read the checklist in docs/RELEASING.md before tagging."

# Build for macOS
build-macos:
	@echo "💻 Building macOS app..."
	flutter build macos $(DART_DEFINES)
	@echo "✅ macOS build complete!"

# Build for Web
build-web:
	@echo "🌐 Building web app..."
	flutter build web $(DART_DEFINES)
	@echo "✅ Web build complete!"

# Run on default device
run:
	@echo "🚀 Running app..."
	flutter run $(DART_DEFINES)

# Run on iOS (default device selector: iphone or pass DEVICE=<id>)
DEVICE ?= iphone
run-ios:
	@echo "🍎 Running on iOS ($(DEVICE))..."
	flutter run -d $(DEVICE) $(DART_DEFINES)

# Run on Android
run-android:
	@echo "🤖 Running on Android..."
	flutter run -d android $(DART_DEFINES)

# Run on Web (Chrome)
run-web:
	@echo "🌐 Running on Chrome..."
	flutter run -d chrome $(DART_DEFINES)

# Run on macOS
run-macos:
	@echo "💻 Running on macOS..."
	flutter run -d macos $(DART_DEFINES)

# Generate app icons from assets/icon/app_icon.png
icons:
	@echo "🖼️  Generating app icons from assets/icon/app_icon.png..."
	dart run flutter_launcher_icons
	@echo "✅ App icons generated!"

# Check Flutter environment
doctor:
	@echo "🩺 Checking Flutter environment..."
	flutter doctor -v

# Full check (format, lint, test)
check: format lint test
	@echo "✅ All checks passed!"

# Pull exported transcript debug logs/fixtures from connected iPhone
pull-fixtures:
	@echo "📥 Pulling exported transcript fixtures from iPhone..."
	mkdir -p test/fixtures/transcripts
	xcrun devicectl device copy from --device 00008150-00184D340EB8401C --domain-type appDataContainer --domain-identifier com.ruach-tech.counta.dev --source Documents --destination test/fixtures/transcripts/
	@rm -f test/fixtures/transcripts/*.hive test/fixtures/transcripts/*.lock
	@echo "✅ JSON transcript fixtures copied to test/fixtures/transcripts/"


# --- Supabase (voice-block Edge Function) -----------------------------------

# Start the local stack; migrations in supabase/migrations are applied on start.
supabase-start:
	@echo "🗄️  Starting local Supabase stack..."
	supabase start
	@echo "✅ Local Supabase running. Put the printed API URL and anon key into .env as SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY."

supabase-stop:
	@echo "🛑 Stopping local Supabase stack..."
	supabase stop

# Deno unit tests for the Edge Function. No stack or network needed.
supabase-test:
	@echo "🧪 Running Edge Function tests..."
	cd supabase/functions && deno test --allow-env --allow-net=127.0.0.1 .
	@echo "✅ Edge Function tests complete!"

# Serve functions locally with secrets from supabase/.env (copy supabase/.env.example).
supabase-serve:
	@echo "⚡ Serving Edge Functions locally..."
	@test -f supabase/.env || (echo "supabase/.env missing: cp supabase/.env.example supabase/.env and fill it in" && exit 1)
	supabase functions serve --env-file supabase/.env

# --- Remote deploys ---------------------------------------------------------
# Runbook: docs/DEPLOYING-BACKEND.md.
#
# The target project comes from `supabase link`, never from this file. The repo
# is public, and the same targets have to work for anyone who links their own
# project; the link lives in supabase/.temp, which is gitignored.
SUPABASE_LINKED_REF = $(shell cat supabase/.temp/project-ref 2>/dev/null)

# Remote secrets live apart from supabase/.env on purpose: the local file points
# `make supabase-serve` at whatever you test with, and pushing it by accident
# would put local values on a live project. The name matches the `*.env`
# ignore rule; remote.env.local would not, which is why it is not that.
SUPABASE_SECRETS_FILE ?= supabase/remote.env

supabase-linked:
	@test -n "$(SUPABASE_LINKED_REF)" || \
		{ echo "❌ Not linked. Run: supabase link --project-ref <ref>"; exit 1; }
	@echo "🔗 Linked project: $(SUPABASE_LINKED_REF)"

# Read-only. What the linked project has, before and after any change.
supabase-status: supabase-linked
	@echo "--- migrations (local vs remote) ---"
	@supabase migration list --linked
	@echo "--- functions ---"
	@supabase functions list --project-ref $(SUPABASE_LINKED_REF)
	@echo "--- secrets (names and digests, never values) ---"
	@supabase secrets list --project-ref $(SUPABASE_LINKED_REF)

# Everything that must hold before code leaves this machine.
#
# The bundle check is the one the README asks for by hand: the test doubles in
# voice-block/testing/ include an attestor that approves every device and a
# balance that never runs out, and they must be unreachable from index.ts. The
# `deno info` output is captured first so a failing `deno info` fails the
# target, rather than reading as zero matches and passing.
supabase-preflight: supabase-test
	@cd supabase/functions && \
		out=$$(deno info voice-block/index.ts) || { echo "❌ deno info failed"; exit 1; }; \
		if echo "$$out" | grep -q "testing/"; then \
			echo "❌ Test doubles are in the bundle graph. Nothing under testing/ may be imported by index.ts."; exit 1; \
		fi
	@echo "✅ No test doubles in the bundle"

# The routine deploy. Safe to re-run: migrations already applied are skipped,
# and a function deploy replaces the previous version.
#
# `db push` is deliberately left interactive. It lists the migrations it is
# about to apply and waits, which is the last look anyone gets before a schema
# change lands on a project other products share.
#
# There is no `supabase config push` here and there must never be one: it
# overwrites the whole project's auth settings. See the runbook.
supabase-deploy: supabase-linked supabase-preflight
	supabase db push --linked
	supabase functions deploy voice-block --project-ref $(SUPABASE_LINKED_REF)
	@$(MAKE) --no-print-directory supabase-smoke

# Secrets are project-wide, not per function: on a shared project they are
# visible to every function any product deploys there. Set only what
# voice-block reads (supabase/.env.example lists it all).
#
# Refuses a tracked file, because `*.env` being ignored is one rule away from
# not being true.
supabase-secrets: supabase-linked
	@test -f "$(SUPABASE_SECRETS_FILE)" || \
		{ echo "❌ $(SUPABASE_SECRETS_FILE) missing: cp supabase/.env.example $(SUPABASE_SECRETS_FILE) and fill it in"; exit 1; }
	@if git ls-files --error-unmatch "$(SUPABASE_SECRETS_FILE)" >/dev/null 2>&1; then \
		echo "❌ $(SUPABASE_SECRETS_FILE) is tracked by git. Untrack it before putting secrets in it."; exit 1; \
	fi
	supabase secrets set --env-file "$(SUPABASE_SECRETS_FILE)" --project-ref $(SUPABASE_LINKED_REF)
	@echo "ℹ️  New secrets reach the function immediately. A *changed* secret may not:"
	@echo "   a warm worker keeps what it booted with. Redeploy to evict it:"
	@echo "   supabase functions deploy voice-block --project-ref $(SUPABASE_LINKED_REF)"

# An anonymous call must be refused by the function itself with 401. That one
# answer proves the function is deployed, verify_jwt=false took effect (the
# gateway would answer differently), and every required secret is present —
# a missing one fails the whole boot with 500 `misconfigured` before auth runs.
supabase-smoke: supabase-linked
	@code=$$(curl -s -o /dev/null -w "%{http_code}" -X POST \
		"https://$(SUPABASE_LINKED_REF).supabase.co/functions/v1/voice-block" \
		-H "Content-Type: application/json" -d '{}'); \
	case $$code in \
		401) echo "✅ voice-block is up, configured, and refusing anonymous calls (401)";; \
		500) echo "❌ 500: deployed but misconfigured. A required secret is missing."; \
		     echo "   Look for boot_failed in the function logs, then: make supabase-secrets"; exit 1;; \
		404) echo "❌ 404: voice-block is not deployed on $(SUPABASE_LINKED_REF)"; exit 1;; \
		*)   echo "❌ Unexpected HTTP $$code from voice-block"; exit 1;; \
	esac

# Prepare for commit
pre-commit: format lint test
	@echo "✅ Ready to commit!"

