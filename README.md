# Counta - Mantra Counter App

A minimalist Flutter app for counting mantras, prayers, or affirmations during meditation and spiritual practice. Designed for simplicity and focus, Counta provides a distraction-free counting experience with customizable alerts and session tracking.

## ✨ Features

- **Resizable Tap Zone**: Adjust the counting area to your preference with a simple drag handle
- **Smart Alerts**: Set threshold and repeat interval alerts with subtle haptic feedback
- **Session Tracking**: Save and review your meditation sessions with notes
- **Multiple Themes**: Choose from 5 beautiful color schemes (Ocean, Forest, Sunset, Mono, Lavender)
- **Haptic Feedback**: Subtle vibrations for tap confirmation and milestone alerts
- **Dark Mode**: Full support for light and dark themes
- **Persistent Settings**: Your preferences and sessions are saved locally using Hive
- **Undo Feature**: Easily correct mistaken taps with the undo button
- **Cross-Platform**: Works on iOS, Android, macOS, Windows, Linux, and Web

## 🚀 Getting Started

### Prerequisites

- Flutter SDK (3.38.8 or higher)
- Dart SDK (3.10.7 or higher)
- For iOS: Xcode and CocoaPods
- For Android: Android Studio and SDK

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/olamide226/counta.git
   cd counta
   ```

2. **Install dependencies**
   ```bash
   flutter pub get
   ```

3. **Generate code for Hive models**
   ```bash
   dart run build_runner build --delete-conflicting-outputs
   ```

4. **Run the app**
   ```bash
   flutter run
   ```

   Or for a specific platform:
   ```bash
   flutter run -d chrome        # Web
   flutter run -d macos         # macOS
   flutter run -d ios           # iOS
   flutter run -d android       # Android
   ```

## 📱 How to Use

1. **Start Counting**: Tap the main counting area to increment your count
2. **Set Alerts**: Tap the Alert button to configure threshold and repeat interval alerts
3. **Adjust Tap Zone**: Drag the handle between the counter and controls to resize the tap area
4. **Save Sessions**: When finished, tap Save to store your session with optional notes
5. **Review History**: View all your saved sessions from the Sessions screen
6. **Customize**: Access Settings to change themes, sound modes, and other preferences
7. **Undo Mistakes**: Tap the Undo button to decrease the count by one

## 🛠️ Tech Stack

- **Framework**: Flutter 3.38.8
- **State Management**: Riverpod 2.6.1
- **Local Database**: Hive 2.2.3
- **Audio**: audioplayers 6.1.0
- **Haptics**: Flutter's HapticFeedback API
- **Code Generation**: build_runner, hive_generator

## 📂 Project Structure

```
lib/
├── main.dart                 # App entry point
├── app.dart                  # Root MaterialApp widget
├── core/
│   ├── services/            # Alert and feedback services
│   └── theme/               # Theme registry and color schemes
├── data/
│   ├── hive/                # Hive initialization
│   └── repositories/        # Data repositories
├── domain/
│   └── models/              # Data models (Hive entities)
├── state/
│   └── providers/           # Riverpod state providers
└── ui/
    ├── screens/             # App screens
    ├── sheets/              # Bottom sheets
    └── widgets/             # Reusable widgets
```

## 🤝 Contributing

Contributions are welcome! Here's how you can help:

1. **Fork the repository**
   ```bash
   git clone https://github.com/olamide226/counta.git
   cd counta
   ```

2. **Create a feature branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

3. **Make your changes**
   - Follow the existing code style and architecture
   - Use Riverpod for state management
   - Add comments for complex logic
   - Ensure Hive models have proper type adapters

4. **Format your code**
   ```bash
   dart format .
   ```

5. **Run code generation if needed**
   ```bash
   dart run build_runner build --delete-conflicting-outputs
   ```

6. **Test your changes**
   ```bash
   flutter test
   flutter run
   ```

7. **Commit and push**
   ```bash
   git add .
   git commit -m "feat: add your feature description"
   git push origin feature/your-feature-name
   ```

8. **Create a Pull Request**
   - Describe your changes clearly
   - Reference any related issues
   - Include screenshots for UI changes

### Code Guidelines

- **Architecture**: Follow clean architecture principles with domain/data/state/ui separation
- **State Management**: Use Riverpod providers for all state
- **Models**: Annotate with Hive type adapters for persistence
- **UI**: Use Material 3 components and respect theme colors
- **Platform Support**: Test on both iOS and Android for haptic/audio features
- **Accessibility**: Consider screen readers and semantic labels

### Areas for Contribution

- [x] Unit tests for counter logic and alert service
- [ ] Integration tests for session workflows
- [ ] Custom sound files for tap feedback
- [ ] Additional theme color schemes
- [ ] Accessibility improvements
- [ ] Localization/internationalization
- [ ] Widget animations (count bump, milestone celebration)
- [ ] Export sessions to CSV/JSON

## 🧪 Testing

The project includes comprehensive unit tests for core business logic. Run tests using:

```bash
make test              # Run all tests
make test-coverage     # Run tests with coverage report
```

### Test Coverage

**Current Coverage: ~27%** (51 tests passing)

While overall coverage is moderate, **all critical business logic is thoroughly tested**:

**✅ Fully Tested Components:**
- **CounterProvider** (13 tests) - Core counter logic, increment/decrement, reset, session management
- **CounterAlertService** (16 tests) - Alert triggering at thresholds and repeat intervals
- **Domain Models** (26 tests) - AppSettings, CountSession, CounterState, Enums validation
- **ThemeRegistry** (8 tests) - All 5 color themes in light/dark modes

**⚠️ Not Covered:**
- UI screens/widgets (requires complex Flutter widget testing)
- Hive data persistence layer (requires database mocking)
- Platform-specific services (haptic feedback, audio playback)

The core application logic that determines app behavior is well-tested and reliable. UI components are manually tested during development.

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🙏 Acknowledgments

Built with Flutter and inspired by the need for a simple, focused meditation companion.

---

**Made with ❤️ for mindful practice**
