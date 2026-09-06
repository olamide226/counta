import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Requirement 9.4: raw audio is never written to disk.
///
/// The audio path lives entirely in `lib/core/services/counting/` (microphone
/// capture, PCM streaming, WebSocket). This test pins the property by
/// inspection: none of those files may touch the file system at all. The only
/// sanctioned write in the app's voice stack is the transcript JSON export on
/// the dev-only debug screen, which carries text, never PCM.
void main() {
  const countingDir = 'lib/core/services/counting';
  const debugScreen = 'lib/ui/screens/debug/streaming_debug_screen.dart';

  final fileSystemMarkers = <String>[
    "import 'dart:io'",
    'package:path_provider',
    'File(',
    'writeAsBytes',
    'writeAsString',
    'openWrite',
    'RandomAccessFile',
  ];

  test('the audio pipeline never imports or calls file-system APIs', () {
    final dir = Directory(countingDir);
    expect(dir.existsSync(), isTrue, reason: 'run from the package root');

    final offenders = <String>[];
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      for (final marker in fileSystemMarkers) {
        if (source.contains(marker)) {
          offenders.add('${entity.path}: $marker');
        }
      }
    }

    expect(offenders, isEmpty);
  });

  test('the debug screen only ever writes the transcript JSON export', () {
    final source = File(debugScreen).readAsStringSync();

    // Exactly one write, and it is a string write of JSON — never bytes.
    expect('writeAsString'.allMatches(source).length, 1);
    expect(source.contains('writeAsBytes'), isFalse);
    expect(source.contains('openWrite'), isFalse);
    // The written content is a JsonEncoder product — the debug screen does
    // forward PCM frames to the socket, but it never puts them in a file.
    expect(source.contains('JsonEncoder'), isTrue);
    expect(source.contains(".json'"), isTrue);
  });
}
