import 'package:flutter/material.dart';

class CountDisplay extends StatelessWidget {
  const CountDisplay({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Count', style: textTheme.titleMedium),
        Text(
          '$count',
          style: textTheme.displayLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
