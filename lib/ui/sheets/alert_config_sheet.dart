import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers/counter_provider.dart';

class AlertConfigSheet extends ConsumerStatefulWidget {
  const AlertConfigSheet({super.key});

  @override
  ConsumerState<AlertConfigSheet> createState() => _AlertConfigSheetState();
}

class _AlertConfigSheetState extends ConsumerState<AlertConfigSheet> {
  late TextEditingController _thresholdController;
  late TextEditingController _repeatController;

  @override
  void initState() {
    super.initState();
    final counter = ref.read(counterProvider);
    _thresholdController = TextEditingController(
      text: counter.threshold?.toString() ?? '',
    );
    _repeatController = TextEditingController(
      text: counter.repeatInterval?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _thresholdController.dispose();
    _repeatController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Alert Settings',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _thresholdController,
            decoration: const InputDecoration(
              labelText: 'Threshold',
              hintText: 'e.g. 100',
              border: OutlineInputBorder(),
              helperText: 'Alert when count reaches this number',
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _repeatController,
            decoration: const InputDecoration(
              labelText: 'Repeat Interval',
              hintText: 'e.g. 100',
              border: OutlineInputBorder(),
              helperText: 'Alert every N counts after threshold',
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _clear,
                  child: const Text('Clear'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _apply,
                  child: const Text('Apply'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _clear() {
    ref.read(counterProvider.notifier).setThreshold(null);
    ref.read(counterProvider.notifier).setRepeatInterval(null);
    Navigator.of(context).pop();
  }

  void _apply() {
    final threshold = int.tryParse(_thresholdController.text);
    final repeat = int.tryParse(_repeatController.text);

    ref.read(counterProvider.notifier).setThreshold(threshold);
    ref.read(counterProvider.notifier).setRepeatInterval(repeat);
    Navigator.of(context).pop();
  }
}

Future<void> showAlertConfigSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => const AlertConfigSheet(),
  );
}
