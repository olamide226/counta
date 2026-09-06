import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:counta/core/services/counting/microphone_permission_service.dart';

void main() {
  group('MicrophonePermissionService', () {
    test('reports whether the settings page opened', () async {
      final service = MicrophonePermissionService(
        openSettings: () async => true,
      );
      expect(await service.openSystemSettings(), isTrue);
    });

    test(
      'a platform without the plugin returns false instead of throwing',
      () async {
        final service = MicrophonePermissionService(
          openSettings: () async => throw MissingPluginException(),
        );
        expect(await service.openSystemSettings(), isFalse);
      },
    );

    test('a platform error returns false instead of throwing', () async {
      final service = MicrophonePermissionService(
        openSettings: () async => throw PlatformException(code: 'nope'),
      );
      expect(await service.openSystemSettings(), isFalse);
    });
  });
}
