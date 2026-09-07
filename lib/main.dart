import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'state/providers/hive_providers.dart';
import 'state/providers/supabase_providers.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(
    ProviderScope(
      child: Consumer(
        builder: (context, ref, _) {
          final hiveInit = ref.watch(hiveInitProvider);

          // Kick off Supabase initialisation and anonymous sign-in at boot,
          // without gating the UI on it: counting must work with no backend.
          ref.listen(supabaseSessionProvider, (_, next) {
            next.whenOrNull(
              error: (err, _) => debugPrint('Supabase sign-in failed: $err'),
            );
          });

          return hiveInit.when(
            data: (_) => const App(),
            loading: () => const MaterialApp(
              home: Scaffold(body: Center(child: CircularProgressIndicator())),
            ),
            error: (err, stack) => MaterialApp(
              home: Scaffold(body: Center(child: Text('Error: $err'))),
            ),
          );
        },
      ),
    ),
  );
}
