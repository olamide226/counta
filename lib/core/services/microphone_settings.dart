import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

/// Opens the app's page in the system settings, where a refused microphone
/// permission can be granted. On iOS that page is the only way to change the
/// answer, so this is the whole of the app's permission UI.
///
/// Requesting the permission itself is `AudioSource`'s job — it is the single
/// owner of that decision. Returns false when the platform could not open the
/// page (Linux, say, where `permission_handler` has no implementation), so the
/// caller can tell the user rather than leave them waiting.
Future<bool> openMicrophoneSettings() async {
  try {
    return await ph.openAppSettings();
  } on MissingPluginException {
    return false;
  } on PlatformException catch (e) {
    debugPrint('Could not open system settings: $e');
    return false;
  }
}
