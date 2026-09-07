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

  test('the debug screen never writes bytes or opens a write stream', () {
    final source = File(debugScreen).readAsStringSync();

    // The debug screen forwards PCM frames to the socket and exports the
    // transcript as text. Only the byte paths would put audio on disk, so
    // those are what this pins — counting its string writes would just break
    // every time the export grows a second one.
    expect(source.contains('writeAsBytes'), isFalse);
    expect(source.contains('openWrite'), isFalse);
    expect(source.contains('RandomAccessFile'), isFalse);
  });
}
