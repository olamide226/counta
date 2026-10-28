import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/app_env.dart';
import '../../core/services/purchases/revenuecat_minute_store.dart';
import '../../domain/purchases/minute_store.dart';
import 'supabase_providers.dart';

/// Where minute packs are bought, or null when this build cannot sell them:
/// no store key for this platform, or no backend to credit the minutes to.
/// The minutes sheet falls back to codes alone then.
final minuteStoreProvider = Provider<MinuteStore?>((ref) {
  final key = AppEnv.revenueCatKey;
  if (key.isEmpty || !AppEnv.hasSupabase) return null;
  return RevenueCatMinuteStore(
    apiKey: key,
    // Read on every call, not captured: see RevenueCatMinuteStore.
    currentUserId: () => Supabase.instance.client.auth.currentUser?.id,
  );
});

/// The packs on sale. Loaded when something first shows them, and again
/// next time after an error, so a sheet reopened later gets a fresh try.
final minutePacksProvider = FutureProvider.autoDispose<List<MinutePack>>((
  ref,
) async {
  final store = ref.watch(minuteStoreProvider);
  if (store == null) return const [];
  // Packs wait for sign-in: a purchase has to land on the account whose
  // balance the voice service reads.
  await ref.watch(supabaseSessionProvider.future);
  return store.packs();
});
