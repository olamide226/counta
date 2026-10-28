import 'dart:typed_data';

import 'package:counta/domain/counting/voice_activity_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// 16 kHz mono PCM16: 32 bytes a millisecond.
const int bytesPerMs = 32;

/// [ms] of PCM16 at a steady level.
Uint8List steady(int amplitude, {int ms = 100}) {
  final data = ByteData(ms * bytesPerMs);
  for (var i = 0; i + 1 < data.lengthInBytes; i += 2) {
    data.setInt16(i, (i ~/ 2).isEven ? amplitude : -amplitude, Endian.little);
  }
  return data.buffer.asUint8List();
}

/// One microphone chunk made of runs of (amplitude, milliseconds).
Uint8List chunk(List<(int, int)> runs) {
  final builder = BytesBuilder();
  for (final (amplitude, ms) in runs) {
    builder.add(steady(amplitude, ms: ms));
  }
  return builder.takeBytes();
}

void main() {
  VoiceActivityDetector detector() =>
      VoiceActivityDetector(bytesPerSecond: 32000);

  /// Feeds chunks and answers whether any of them fired.
  bool feed(VoiceActivityDetector d, Iterable<Uint8List> chunks) =>
      chunks.map(d.add).toList().contains(true);

  /// Two seconds of a quiet room, in 100 ms chunks as iOS delivers them.
  List<Uint8List> quietRoom() => List.filled(20, steady(20));

  test('silence never starts anything', () {
    expect(feed(detector(), List.filled(300, steady(0))), isFalse);
  });

  test('a quiet room never starts anything', () {
    expect(feed(detector(), List.filled(300, steady(40))), isFalse);
  });

  test('a voice starts it within a fraction of a second', () {
    final d = detector();
    feed(d, quietRoom());

    final fired = [for (var i = 0; i < 5; i++) d.add(steady(1500))];

    // 160 ms of speech lands in the second 100 ms chunk.
    expect(fired.indexOf(true), 1);
  });

  test('a soft voice, close to the phone, still starts it', () {
    final d = detector();
    feed(d, quietRoom());
    // About -45 dBFS: the level quiet speech registered at on a real phone.
    expect(feed(d, List.filled(3, steady(180))), isTrue);
  });

  test('a soft voice that dips between sounds still starts it', () {
    // Speech is not a steady tone: a quiet voice drops under the minimum
    // between sounds. Two loud slices in three is still a voice.
    final d = detector();
    feed(d, quietRoom());
    final uneven = [
      for (var i = 0; i < 3; i++) chunk([(200, 40), (90, 20), (200, 40)]),
    ];
    expect(feed(d, uneven), isTrue);
  });

  test('a voice from the very first chunk is still heard', () {
    // Someone who speaks the instant they press Start must not teach the
    // detector that their voice is the room.
    expect(feed(detector(), List.filled(3, steady(1500))), isTrue);
  });

  test('a knock inside a chunk is not a voice', () {
    // Regression: judged per 100 ms chunk, a 20 ms knock made the whole
    // chunk loud, and a knock with its echo started a session on a real
    // phone at level 3807.
    final d = detector();
    feed(d, quietRoom());
    final knock = chunk([(8000, 20), (1200, 20), (20, 60)]);
    expect(d.add(knock), isFalse);
    expect(feed(d, quietRoom()), isFalse);
  });

  test('knocking a few times is not a voice either', () {
    final d = detector();
    feed(d, quietRoom());
    final knocks = [
      for (var i = 0; i < 4; i++) ...[
        chunk([(8000, 20), (1200, 20), (20, 60)]),
        chunk([(20, 100)]),
      ],
    ];
    expect(feed(d, knocks), isFalse);
  });

  test('chunks of any size are judged the same', () {
    // The microphone's chunk size is the platform's choice, not ours.
    final d = detector();
    feed(d, [for (var i = 0; i < 70; i++) steady(20, ms: 30)]);
    final fired = [for (var i = 0; i < 20; i++) d.add(steady(1500, ms: 13))];
    expect(fired, contains(true));
  });

  test('a noisy room starts it early, which costs what it did before', () {
    // The failure it leans towards on purpose: steady noise above the
    // minimum reads as a voice, and the session starts streaming — exactly
    // what happened before there was a wait at all.
    expect(feed(detector(), List.filled(5, steady(400))), isTrue);
  });

  test('a hum under the minimum is ignored', () {
    expect(feed(detector(), List.filled(100, steady(90))), isFalse);
  });

  test('it decides once', () {
    final d = detector();
    expect(feed(d, List.filled(3, steady(1500))), isTrue);
    expect(feed(d, List.filled(10, steady(1500))), isFalse);
  });
}
