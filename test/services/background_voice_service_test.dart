import 'package:counta/core/services/background_voice_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> calls;
  late bool grant;

  BackgroundVoiceService service({
    bool supported = true,
    Duration interval = Duration.zero,
    DateTime Function()? now,
  }) => BackgroundVoiceService(
    supported: supported,
    updateInterval: interval,
    now: now,
    start: (title, count) async {
      calls.add('start $title');
      return grant;
    },
    update: (title, count) async => calls.add('update $title $count'),
    stop: () async => calls.add('stop'),
  );

  setUp(() {
    calls = [];
    grant = true;
  });

  test('starts once while active and stops when the session ends', () async {
    final s = service();
    await s.setActive(true, title: 'a', count: 0);
    await s.setActive(true, title: 'a', count: 0);
    expect(s.isHeld, isTrue);
    await s.setActive(false, title: 'a', count: 0);
    await s.setActive(false, title: 'a', count: 0);
    expect(calls, ['start a', 'stop']);
    expect(s.isHeld, isFalse);
  });

  test('a declined start is asked for again on the next change', () async {
    final s = service();
    grant = false;
    await s.setActive(true, title: 'a', count: 0);
    expect(s.isHeld, isFalse);
    // Nothing is running, so ending the session has nothing to stop.
    await s.setActive(false, title: 'a', count: 0);
    grant = true;
    await s.setActive(true, title: 'a', count: 0);
    expect(s.isHeld, isTrue);
    expect(calls, ['start a', 'start a']);
  });

  test('overlapping starts reach the platform once', () async {
    final s = service();
    await Future.wait([
      s.setActive(true, title: 'a', count: 0),
      s.setActive(true, title: 'a', count: 0),
    ]);
    expect(calls, ['start a']);
  });

  test('a platform failure is not fatal and is retried', () async {
    var fail = true;
    final s = BackgroundVoiceService(
      supported: true,
      start: (_, _) async {
        if (fail) throw Exception('refused');
        return true;
      },
      stop: () async {},
    );
    await s.setActive(true, title: 'a', count: 0);
    expect(s.isHeld, isFalse);
    fail = false;
    await s.setActive(true, title: 'a', count: 0);
    expect(s.isHeld, isTrue);
  });

  test('does nothing off Android', () async {
    final s = service(supported: false);
    await s.setActive(true, title: 'a', count: 0);
    await s.setActive(false, title: 'a', count: 0);
    expect(calls, isEmpty);
    expect(s.isHeld, isFalse);
  });

  test('the notification follows the count', () async {
    final s = service();
    await s.setActive(true, title: 'a', count: 0);
    await s.setActive(true, title: 'a', count: 1);
    await s.setActive(true, title: 'a', count: 1);
    await s.setActive(true, title: 'a', count: 2);
    expect(calls, ['start a', 'update a 1', 'update a 2']);
  });

  test(
    'fast counts are sent at most once an interval, ending on the latest',
    () {
      fakeAsync((async) {
        final s = service(
          interval: const Duration(seconds: 1),
          now: () => DateTime(2026).add(async.elapsed),
        );
        s.setActive(true, title: 'a', count: 0);
        async.flushMicrotasks();
        for (var count = 1; count <= 5; count++) {
          s.setActive(true, title: 'a', count: count);
          async.elapse(const Duration(milliseconds: 100));
        }
        // Within the first interval: nothing yet beyond the start.
        expect(calls, ['start a']);
        async.elapse(const Duration(seconds: 1));
        expect(calls, ['start a', 'update a 5']);
        s.setActive(false, title: 'a', count: 5);
        async.flushMicrotasks();
      });
    },
  );
}
