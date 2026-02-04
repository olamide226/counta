import 'package:flutter_test/flutter_test.dart';
import 'package:counta/domain/models/count_session.dart';
import 'package:counta/domain/models/enums.dart';

void main() {
  group('CountSession', () {
    test('creates session with all required fields', () {
      final now = DateTime.now();

      final session = CountSession(
        mantra: 'Om Mani Padme Hum',
        startedAt: now,
        endedAt: now.add(const Duration(minutes: 30)),
        finalCount: 100,
        threshold: 100,
        repeatInterval: 100,
        soundMode: SoundMode.vibrate,
        themeModeChoice: ThemeModeChoice.system,
        themeId: AppThemeId.ocean,
        notes: 'Test session',
      );

      expect(session.mantra, 'Om Mani Padme Hum');
      expect(session.startedAt, now);
      expect(session.endedAt, now.add(const Duration(minutes: 30)));
      expect(session.finalCount, 100);
      expect(session.threshold, 100);
      expect(session.repeatInterval, 100);
      expect(session.soundMode, SoundMode.vibrate);
      expect(session.themeModeChoice, ThemeModeChoice.system);
      expect(session.themeId, AppThemeId.ocean);
      expect(session.notes, 'Test session');
    });

    test('generates unique ID if not provided', () {
      final now = DateTime.now();

      final session1 = CountSession(
        mantra: 'Om',
        startedAt: now,
        endedAt: now,
        finalCount: 10,
        soundMode: SoundMode.mute,
        themeModeChoice: ThemeModeChoice.light,
        themeId: AppThemeId.forest,
      );

      final session2 = CountSession(
        mantra: 'Om',
        startedAt: now,
        endedAt: now,
        finalCount: 10,
        soundMode: SoundMode.mute,
        themeModeChoice: ThemeModeChoice.light,
        themeId: AppThemeId.forest,
      );

      expect(session1.id, isNot(session2.id));
      expect(session1.id, isNotEmpty);
      expect(session2.id, isNotEmpty);
    });

    test('can use custom ID', () {
      final now = DateTime.now();

      final session = CountSession(
        id: 'custom-id-123',
        mantra: 'Test',
        startedAt: now,
        endedAt: now,
        finalCount: 50,
        soundMode: SoundMode.vibrate,
        themeModeChoice: ThemeModeChoice.dark,
        themeId: AppThemeId.sunset,
      );

      expect(session.id, 'custom-id-123');
    });

    test('can create session with null optional fields', () {
      final now = DateTime.now();

      final session = CountSession(
        mantra: 'Om',
        startedAt: now,
        endedAt: now,
        finalCount: 10,
        threshold: null,
        repeatInterval: null,
        soundMode: SoundMode.mute,
        themeModeChoice: ThemeModeChoice.system,
        themeId: AppThemeId.mono,
        notes: null,
        deviceLocale: null,
      );

      expect(session.threshold, null);
      expect(session.repeatInterval, null);
      expect(session.notes, null);
      expect(session.deviceLocale, null);
    });

    test('duration calculation works correctly', () {
      final start = DateTime(2026, 2, 2, 10, 0, 0);
      final end = DateTime(2026, 2, 2, 10, 30, 0);

      final session = CountSession(
        mantra: 'Test',
        startedAt: start,
        endedAt: end,
        finalCount: 100,
        soundMode: SoundMode.vibrate,
        themeModeChoice: ThemeModeChoice.light,
        themeId: AppThemeId.ocean,
      );

      expect(session.endedAt.difference(session.startedAt).inMinutes, 30);
    });

    test('stores settings snapshot at session time', () {
      final now = DateTime.now();

      final session = CountSession(
        mantra: 'Test',
        startedAt: now,
        endedAt: now,
        finalCount: 50,
        threshold: 100,
        repeatInterval: 25,
        soundMode: SoundMode.sound,
        themeModeChoice: ThemeModeChoice.dark,
        themeId: AppThemeId.lavender,
      );

      // Session should preserve these values
      expect(session.threshold, 100);
      expect(session.repeatInterval, 25);
      expect(session.soundMode, SoundMode.sound);
      expect(session.themeModeChoice, ThemeModeChoice.dark);
      expect(session.themeId, AppThemeId.lavender);
    });

    test('handles empty mantra', () {
      final now = DateTime.now();

      final session = CountSession(
        mantra: '',
        startedAt: now,
        endedAt: now,
        finalCount: 0,
        soundMode: SoundMode.mute,
        themeModeChoice: ThemeModeChoice.system,
        themeId: AppThemeId.ocean,
      );

      expect(session.mantra, '');
    });

    test('handles zero count', () {
      final now = DateTime.now();

      final session = CountSession(
        mantra: 'Test',
        startedAt: now,
        endedAt: now,
        finalCount: 0,
        soundMode: SoundMode.vibrate,
        themeModeChoice: ThemeModeChoice.light,
        themeId: AppThemeId.forest,
      );

      expect(session.finalCount, 0);
    });

    test('handles large count values', () {
      final now = DateTime.now();

      final session = CountSession(
        mantra: 'Test',
        startedAt: now,
        endedAt: now,
        finalCount: 10000,
        soundMode: SoundMode.soundAndVibrate,
        themeModeChoice: ThemeModeChoice.system,
        themeId: AppThemeId.sunset,
      );

      expect(session.finalCount, 10000);
    });

    test('can include device locale', () {
      final now = DateTime.now();

      final session = CountSession(
        mantra: 'Test',
        startedAt: now,
        endedAt: now,
        finalCount: 50,
        soundMode: SoundMode.vibrate,
        themeModeChoice: ThemeModeChoice.system,
        themeId: AppThemeId.mono,
        deviceLocale: 'en_US',
      );

      expect(session.deviceLocale, 'en_US');
    });
  });
}
