import 'package:counta/core/services/background_voice_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> calls;
  late bool grant;

  BackgroundVoiceService service({bool supported = true}) =>
      BackgroundVoiceService(
        supported: supported,
        start: (title) async {
          calls.add('start $title');
          return grant;
        },
        stop: () async => calls.add('stop'),
      );

  setUp(() {
    calls = [];
    grant = true;
  });

  test('starts once while active and stops when the session ends', () async {
    final s = service();
    await s.setActive(true, title: 'a');
    await s.setActive(true, title: 'a');
    expect(s.isHeld, isTrue);
    await s.setActive(false, title: 'a');
    await s.setActive(false, title: 'a');
    expect(calls, ['start a', 'stop']);
    expect(s.isHeld, isFalse);
  });

  test('a declined start is asked for again on the next change', () async {
    final s = service();
    grant = false;
    await s.setActive(true, title: 'a');
    expect(s.isHeld, isFalse);
    // Nothing is running, so ending the session has nothing to stop.
    await s.setActive(false, title: 'a');
    grant = true;
    await s.setActive(true, title: 'a');
    expect(s.isHeld, isTrue);
    expect(calls, ['start a', 'start a']);
  });

  test('overlapping starts reach the platform once', () async {
    final s = service();
    await Future.wait([
      s.setActive(true, title: 'a'),
      s.setActive(true, title: 'a'),
    ]);
    expect(calls, ['start a']);
  });

  test('a platform failure is not fatal and is retried', () async {
    var fail = true;
    final s = BackgroundVoiceService(
      supported: true,
      start: (_) async {
        if (fail) throw Exception('refused');
        return true;
      },
      stop: () async {},
    );
    await s.setActive(true, title: 'a');
    expect(s.isHeld, isFalse);
    fail = false;
    await s.setActive(true, title: 'a');
    expect(s.isHeld, isTrue);
  });

  test('does nothing off Android', () async {
    final s = service(supported: false);
    await s.setActive(true, title: 'a');
    await s.setActive(false, title: 'a');
    expect(calls, isEmpty);
    expect(s.isHeld, isFalse);
  });
}
