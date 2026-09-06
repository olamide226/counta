import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

/// Thin wrapper around the OS permission settings for the microphone.
///
/// Requesting the permission itself is `AudioSource`'s job (the `record`
/// plugin prompts as part of `hasPermission()`). This service only covers what
/// that plugin cannot: sending the user to the system settings page once they
/// have refused, which on iOS is the only way to change the answer.
class MicrophonePermissionService {
  /// [openSettings] exists so tests and unsupported platforms can substitute
  /// the plugin call.
  MicrophonePermissionService({Future<bool> Function()? openSettings})
    : _openSettings = openSettings ?? _defaultOpenSettings;

  final Future<bool> Function() _openSettings;

  static Future<bool> _defaultOpenSettings() => ph.openAppSettings();

  /// Opens the app's page in the system settings, where the microphone
  /// permission can be granted. Returns false if the platform could not do it
  /// (e.g. Linux, where permission_handler has no implementation).
  Future<bool> openSystemSettings() async {
    try {
      return await _openSettings();
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint('Could not open system settings: $e');
      return false;
    }
  }
}
