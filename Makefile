.PHONY: help setup format lint analyze test test-corpus test-coverage build-runner clean build-ios build-ios-ipa build-android build-macos build-web run run-ios run-android run-web doctor icons pull-fixtures supabase-start supabase-stop supabase-test supabase-serve

# Environment Configuration
# Automatically loads variables from .env file if present, or CLI overrides
-include .env
DEEPGRAM_API_KEY ?=
SUPABASE_URL ?=
SUPABASE_PUBLISHABLE_KEY ?=

# With a .env every key in it becomes a dart-define. Without one, forward
# whichever of the known keys were passed on the command line.
DART_DEFINES := $(if $(wildcard .env),--dart-define-from-file=.env,\
	$(if $(DEEPGRAM_API_KEY),--dart-define=DEEPGRAM_API_KEY=$(DEEPGRAM_API_KEY),) \
	$(if $(SUPABASE_URL),--dart-define=SUPABASE_URL=$(SUPABASE_URL),) \
	$(if $(SUPABASE_PUBLISHABLE_KEY),--dart-define=SUPABASE_PUBLISHABLE_KEY=$(SUPABASE_PUBLISHABLE_KEY),))


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
	@echo "Build commands (supports DEEPGRAM_API_KEY=...):"
	@echo "  make build-ios      - Build iOS app (debug/ad-hoc)"
	@echo "  make build-ios-ipa  - Build iOS archive for App Store/TestFlight"
	@echo "  make build-android  - Build Android APK"
	@echo "  make build-macos    - Build macOS app"
	@echo "  make build-web      - Build web app"
	@echo ""
	@echo "Run commands (supports DEEPGRAM_API_KEY=...):"
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

# Build iOS archive (.ipa) for App Store / TestFlight
build-ios-ipa:
	@echo "🍎 Building iOS archive..."
	flutter build ipa $(DART_DEFINES)
	@echo "✅ iOS archive ready at build/ios/archive/Runner.xcarchive"
	@echo "   Upload via Xcode Organizer: open build/ios/archive/Runner.xcarchive"

# Build for Android
build-android:
	@echo "🤖 Building Android APK..."
	flutter build apk $(DART_DEFINES)
	@echo "✅ Android build complete!"

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

