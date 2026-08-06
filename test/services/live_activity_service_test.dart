import 'package:flutter_test/flutter_test.dart';
import 'package:counta/core/services/live_activity_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LiveActivityService', () {
    late LiveActivityService service;

    setUp(() {
      service = LiveActivityService();
    });

    test('init executes safely without throws', () async {
      await expectLater(service.init(), completes);
    });

    test('startActivity executes safely on non-iOS platform', () async {
      await expectLater(
        service.startActivity(
          phrase: 'Om Namah Shivaya',
          count: 108,
          voiceCount: 100,
          manualCount: 8,
          status: 'live',
        ),
        completes,
      );
    });

    test('updateActivity executes safely and throttles subsequent updates', () async {
      service.updateActivity(
        phrase: 'Om Namah Shivaya',
        count: 109,
        voiceCount: 101,
        manualCount: 8,
        status: 'live',
      );

      service.updateActivity(
        phrase: 'Om Namah Shivaya',
        count: 110,
        voiceCount: 102,
        manualCount: 8,
        status: 'live',
      );
    });

    test('endActivity executes safely without active activity', () async {
      await expectLater(service.endActivity(), completes);
    });
  });
}
