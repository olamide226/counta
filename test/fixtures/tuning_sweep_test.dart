import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:counta/domain/counting/phrase_matcher.dart';

import 'fixture_replay_harness.dart';

/// Parameter sweep for task 4.7 — reports how recall and false positives move
/// as the matcher constants change, across whatever fixtures are recorded.
///
/// This asserts nothing. It exists to make tuning a reading exercise rather
/// than a guessing one. Run it with:
///
/// ```bash
/// flutter test test/fixtures/tuning_sweep_test.dart
/// ```
void main() {
  final dir = Directory('test/fixtures/transcripts');

  test('parameter sweep across the fixture corpus', () {
    final files = dir.existsSync()
        ? (dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
        : <File>[];

    if (files.isEmpty) {
      markTestSkipped('No fixtures recorded yet (task 3.1)');
      return;
    }

    void sweep<T>(
      String label,
      List<T> values,
      MatcherConfig Function(T) build,
    ) {
      // ignore: avoid_print
      print('\n=== $label ===');
      for (final file in files) {
        final name = file.path.split('/').last.replaceAll('.json', '');
        final json = file.readAsStringSync();
        final cells = <String>[];

        for (final value in values) {
          final harness = FixtureReplayHarness(config: build(value));
          final r = harness.evaluateFixtureJson(json, fixtureName: name);
          cells.add('$value:${(r.recall * 100).toStringAsFixed(0)}%');
        }
        // ignore: avoid_print
        print('${name.padRight(20)} ${cells.join('  ')}');
      }
    }

    sweep<int>('refractoryFloorMs (recall)', const [
      1200,
      1000,
      800,
      600,
      400,
      300,
    ], (v) => MatcherConfig(refractoryFloorMs: v));

    sweep<double>('threshold (recall)', const [
      0.90,
      0.85,
      0.80,
      0.75,
      0.70,
    ], (v) => MatcherConfig(threshold: v));

    sweep<double>('anchoredThreshold (recall)', const [
      0.80,
      0.70,
      0.65,
      0.60,
      0.50,
    ], (v) => MatcherConfig(anchoredThreshold: v));

    sweep<double>(
      'refractoryMultiplier with no floor (recall)',
      const [0.0, 0.20, 0.40, 0.60],
      (v) => MatcherConfig(refractoryFloorMs: 0, refractoryMultiplier: v),
    );

    // ignore: avoid_print
    print(
      '\nRecall above 100% means false positives — check the gate table in '
      'corpus_test.dart for the FP/10min figure before lowering a value.\n',
    );
  });
}
