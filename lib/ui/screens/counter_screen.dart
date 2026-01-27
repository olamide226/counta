import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers/counter_provider.dart';
import '../widgets/count_display.dart';
import '../widgets/quick_controls_bar.dart';
import '../widgets/resizable_tap_layout.dart';
import '../widgets/tap_zone.dart';

class CounterScreen extends ConsumerWidget {
  const CounterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counter = ref.watch(counterProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Mantra Counter'), centerTitle: true),
      body: SafeArea(
        child: ResizableTapLayout(
          tapChild: TapZone(
            onTap: () => ref.read(counterProvider.notifier).increment(),
          ),
          infoChild: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CountDisplay(count: counter.count),
                const SizedBox(height: 24),
                QuickControlsBar(
                  onReset: () => ref.read(counterProvider.notifier).reset(),
                  onSave: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Save flow coming next.')),
                    );
                  },
                  onAlertConfig: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Alert settings coming next.'),
                      ),
                    );
                  },
                  onSoundMode: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Sound mode coming next.')),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
