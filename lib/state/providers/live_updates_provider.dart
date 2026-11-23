import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/background_voice_service.dart';
import 'app_lifecycle_provider.dart';
import 'services_provider.dart';

/// Whether Counta's counting notification can be an Android Live Update.
/// Re-read each time the app comes back to the foreground, since the switch
/// lives in system settings.
final liveUpdatesProvider = FutureProvider.autoDispose<LiveUpdates>((ref) {
  ref.watch(
    appLifecycleProvider.select((state) => state == AppLifecycleState.resumed),
  );
  return ref.read(backgroundVoiceServiceProvider).liveUpdates();
});
