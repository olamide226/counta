import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fixture_replay_harness.dart';

/// Runs every recorded fixture through the matcher and prints the task 3.4
/// gate table.
///
/// Skips cleanly when no fixtures have been recorded yet, so the suite stays
/// green before the corpus exists. Once `test/fixtures/transcripts/*.json`
/// is populated, this is the accuracy baseline.
void main() {
  final dir = Directory('test/fixtures/transcripts');

  test('fixture corpus meets the recall gate', () async {
    if (!dir.existsSync()) {
      markTestSkipped('No test/fixtures/transcripts directory yet (task 3.1)');
      return;
    }

    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    if (files.isEmpty) {
      markTestSkipped('No fixtures recorded yet (task 3.1)');
      return;
    }

    final harness = FixtureReplayHarness();
    final results = <FixtureResult>[];

    for (final file in files) {
      results.add(await harness.evaluateFixtureFile(file));
    }

    // ignore: avoid_print
    print('\n${'fixture'.padRight(22)}  true  det   recall   FP/10m  gate');
    // ignore: avoid_print
    print('-' * 62);
    for (final r in results) {
      // ignore: avoid_print
      print('${r.fixtureName.padRight(22)}  '
          '${r.trueCount.toString().padLeft(4)}  '
          '${r.detectedCount.toString().padLeft(3)}  '
          '${(r.recall * 100).toStringAsFixed(1).padLeft(6)}%  '
          '${r.falsePositivesPer10Min.toStringAsFixed(1).padLeft(6)}  '
          '${r.passedGate ? "PASS" : "FAIL"}');
    }
    // ignore: avoid_print
    print('');

    // Task 3.4 gates on `normal` specifically. The noisier fixtures are
    // reported for tuning in task 4.7 but are not blocking here.
    final normal = results.where((r) => r.fixtureName.startsWith('normal'));
    if (normal.isEmpty) {
      markTestSkipped('No `normal_*` fixture recorded yet — gate not evaluated');
      return;
    }

    for (final r in normal) {
      expect(
        r.recall,
        greaterThanOrEqualTo(0.95),
        reason: 'Task 3.4 gate: recall on ${r.fixtureName} must be >= 0.95. '
            'Got ${(r.recall * 100).toStringAsFixed(1)}%.',
      );
    }
  });
}
