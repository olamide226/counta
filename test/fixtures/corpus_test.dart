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

  _noCrossTalkGate(dir);

  test('fixture corpus meets the recall gate', () async {
    if (!dir.existsSync()) {
      markTestSkipped('No test/fixtures/transcripts directory yet (task 3.1)');
      return;
    }

    final files =
        dir
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
    print(
      '\n${'fixture'.padRight(22)}  true  txed  det   recall  m.rec   txcov   FP/10m  gate',
    );
    // ignore: avoid_print
    print('-' * 84);
    for (final r in results) {
      // ignore: avoid_print
      print(
        '${r.fixtureName.padRight(22)}  '
        '${r.trueCount.toString().padLeft(4)}  '
        '${r.transcribedRepetitions.toString().padLeft(4)}  '
        '${r.detectedCount.toString().padLeft(3)}  '
        '${(r.recall * 100).toStringAsFixed(1).padLeft(6)}%  '
        '${(r.matcherRecall * 100).toStringAsFixed(1).padLeft(5)}%  '
        '${(r.transcriptTokenCoverage * 100).toStringAsFixed(1).padLeft(5)}%  '
        '${r.falsePositivesPer10Min.toStringAsFixed(1).padLeft(6)}  '
        // Too few repetitions to hold to a percentage: shown, not judged.
        '${!r.isGateable ? "info" : (r.passedGate ? "PASS" : "FAIL")}',
      );
      // A set gets one row per phrase beneath its total, which is where a
      // phrase that is not being heard shows up: detections far below what
      // the transcript holds for it.
      if (r.isMultiPhrase) {
        for (final phrase in r.phrases) {
          final label = phrase.phrase.length > 20
              ? '${phrase.phrase.substring(0, 19)}…'
              : phrase.phrase;
          // ignore: avoid_print
          print(
            '  ${label.padRight(20)}  '
            '${(phrase.trueCount?.toString() ?? '-').padLeft(4)}  '
            '${phrase.transcribedRepetitions.toString().padLeft(4)}  '
            '${phrase.detectedCount.toString().padLeft(3)}  '
            '${''.padLeft(7)}  '
            '${(phrase.matcherRecall * 100).toStringAsFixed(1).padLeft(5)}%'
            '${phrase.anchorShared ? '  ~ shares every word with another phrase' : ''}',
          );
        }
      }
    }
    // ignore: avoid_print
    print('');

    // Task 3.4 gates on `normal` specifically. The noisier fixtures are
    // reported for tuning in task 4.7 but are not blocking here.
    //
    // The gate is the matcher's recall against what was *transcribed*
    // (`m.rec`), not against `true_count`. The user pauses mid-session, so the
    // recording contains long silences that no matcher change can recover;
    // `recall` and `txcov` are printed so a bad recording is still visible.
    // Only fixtures with enough repetitions for a percentage to measure the
    // matcher rather than one bad patch of transcription; see
    // [FixtureReplayHarness.minGatedRepetitions].
    final normal = results.where(
      (r) => r.fixtureName.startsWith('normal') && r.isGateable,
    );
    if (normal.isEmpty) {
      markTestSkipped(
        'No `normal_*` fixture with at least '
        '${FixtureReplayHarness.minGatedRepetitions} transcribed repetitions '
        'yet — gate not evaluated',
      );
      return;
    }

    for (final r in normal) {
      expect(
        r.matcherRecall,
        greaterThanOrEqualTo(0.95),
        reason:
            'Task 3.4 gate: matcher recall on ${r.fixtureName} must be >= 0.95. '
            'Detected ${r.detectedCount} of ${r.transcribedRepetitions} '
            'transcribed repetitions '
            '(${(r.matcherRecall * 100).toStringAsFixed(1)}%).',
      );
    }
  });
}

/// The one risk a multi-phrase session adds: every extra phrase is another
/// chance for a stretch of real speech to clear the threshold against
/// something the user never said.
///
/// Hand-written segments cannot show this — the interference only appears
/// over hours of real, garbled transcript. So the corpus is replayed twice:
/// once with the fixture's own phrase, and once with four unrelated phrases
/// listening alongside it. The fixture's own count must not move, and the
/// unrelated phrases must count nothing.
void _noCrossTalkGate(Directory dir) {
  test('unrelated phrases do not disturb the phrase being counted', () async {
    if (!dir.existsSync()) {
      markTestSkipped('No test/fixtures/transcripts directory yet (task 3.1)');
      return;
    }

    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    if (files.isEmpty) {
      markTestSkipped('No fixtures recorded yet (task 3.1)');
      return;
    }

    // Deliberately plausible for this corpus: devotional phrasing of a
    // similar length and register, sharing function words with the target.
    // Nonsense strings would prove nothing.
    const distractors = [
      'I walk in favour',
      'My health is renewed',
      'the peace of god is at work in me',
      'I am full of power',
    ];

    final harness = FixtureReplayHarness();

    for (final file in files) {
      final json = await file.readAsString();
      final name = file.uri.pathSegments.last;

      final alone = harness.evaluateFixtureJson(json, fixtureName: name);
      final crowded = harness.evaluateFixtureJson(
        json,
        fixtureName: name,
        extraPhrases: distractors,
      );

      // Two separate claims, because a total alone cannot tell them apart: a
      // distractor that *stole* one of the real phrase's repetitions leaves
      // the total exactly where it was.
      expect(
        crowded.distractorDetections,
        0,
        reason:
            '$name: phrases the speaker never said claimed '
            '${crowded.distractorDetections} detection(s). A phrase the audio '
            'does not contain must claim nothing.',
      );
      expect(
        [for (final phrase in crowded.phrases) phrase.detectedCount],
        [for (final phrase in alone.phrases) phrase.detectedCount],
        reason:
            '$name: counting ${distractors.length} unrelated phrases '
            "alongside changed what the fixture's own phrase counted.",
      );
    }
  });
}
