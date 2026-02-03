.PHONY: help setup format lint analyze test test-coverage build-runner clean build-ios build-android build-macos build-web run run-ios run-android run-web doctor

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
	@echo "  make test-coverage  - Run tests with coverage report"
	@echo "  make build-runner   - Generate code for Hive models"
	@echo "  make clean          - Clean build artifacts"
	@echo ""
	@echo "Build commands:"
	@echo "  make build-ios      - Build iOS app"
	@echo "  make build-android  - Build Android APK"
	@echo "  make build-macos    - Build macOS app"
	@echo "  make build-web      - Build web app"
	@echo ""
	@echo "Run commands:"
	@echo "  make run            - Run app (default device)"
	@echo "  make run-ios        - Run on iOS"
	@echo "  make run-android    - Run on Android"
	@echo "  make run-web        - Run on Chrome"
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
	flutter build ios
	@echo "✅ iOS build complete!"

# Build for Android
build-android:
	@echo "🤖 Building Android APK..."
	flutter build apk
	@echo "✅ Android build complete!"

# Build for macOS
build-macos:
	@echo "💻 Building macOS app..."
	flutter build macos
	@echo "✅ macOS build complete!"

# Build for Web
build-web:
	@echo "🌐 Building web app..."
	flutter build web
	@echo "✅ Web build complete!"

# Run on default device
run:
	@echo "🚀 Running app..."
	flutter run

# Run on iOS
run-ios:
	@echo "🍎 Running on iOS..."
	flutter run -d ios

# Run on Android
run-android:
	@echo "🤖 Running on Android..."
	flutter run -d android

# Run on Web (Chrome)
run-web:
	@echo "🌐 Running on Chrome..."
	flutter run -d chrome

# Run on macOS
run-macos:
	@echo "💻 Running on macOS..."
	flutter run -d macos

# Check Flutter environment
doctor:
	@echo "🩺 Checking Flutter environment..."
	flutter doctor -v

# Full check (format, lint, test)
check: format lint test
	@echo "✅ All checks passed!"

# Prepare for commit
pre-commit: format lint test
	@echo "✅ Ready to commit!"
