.PHONY: help setup format lint analyze test test-corpus test-coverage build-runner clean build-ios build-ios-ipa build-android build-appbundle release-preflight build-macos build-web run run-ios run-android run-web doctor icons pull-fixtures supabase-start supabase-stop supabase-test supabase-serve

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

# Prepare for commit
pre-commit: format lint test
	@echo "✅ Ready to commit!"

