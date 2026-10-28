import 'dart:typed_data';

import 'package:counta/domain/counting/voice_activity_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// 100 ms of PCM16 at 16 kHz mono, at a steady level.
Uint8List frame(int amplitude, {int bytes = 3200}) {
  final data = ByteData(bytes);
  for (var i = 0; i + 1 < bytes; i += 2) {
    data.setInt16(i, (i ~/ 2).isEven ? amplitude : -amplitude, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  VoiceActivityDetector detector() =>
      VoiceActivityDetector(bytesPerSecond: 32000);

  /// Feeds frames and answers whether any of them fired.
  bool feed(VoiceActivityDetector d, Iterable<Uint8List> frames) =>
      frames.map(d.add).toList().contains(true);

  test('silence never starts anything', () {
    final d = detector();
    expect(feed(d, List.filled(300, frame(0))), isFalse);
  });

  test('a quiet room never starts anything', () {
    final d = detector();
    expect(feed(d, List.filled(300, frame(40))), isFalse);
  });

  test('a voice starts it within a fraction of a second', () {
    final d = detector();
    feed(d, List.filled(20, frame(20)));

    final fired = [for (var i = 0; i < 5; i++) d.add(frame(1500))];

    // 150 ms of speech is two 100 ms frames.
    expect(fired.indexOf(true), 1);
  });

  test('a quiet voice, close to the phone, still starts it', () {
    final d = detector();
    feed(d, List.filled(20, frame(15)));
    // About -45 dBFS: a soft voice, not a shout.
    expect(feed(d, List.filled(3, frame(180))), isTrue);
  });

  test('a voice from the very first frame is still heard', () {
    // Someone who starts speaking the instant they press Start must not
    // teach the detector that their voice is the room.
    final d = detector();
    expect(feed(d, List.filled(3, frame(1500))), isTrue);
  });

  test('a click is not a voice', () {
    final d = detector();
    feed(d, List.filled(20, frame(20)));
    // 20 ms of loud: a tap sound, a knock.
    expect(d.add(frame(8000, bytes: 640)), isFalse);
    expect(feed(d, List.filled(20, frame(20))), isFalse);
  });

  test('a short pause between syllables does not reset it', () {
    final d = detector();
    feed(d, List.filled(20, frame(20)));
    expect(d.add(frame(1500, bytes: 1600)), isFalse); // 50 ms
    expect(d.add(frame(20, bytes: 3200)), isFalse); // 100 ms gap
    expect(d.add(frame(1500, bytes: 3200)), isTrue); // 100 ms more
  });

  test('a noisy room starts it early, which costs what it did before', () {
    // The failure it leans towards on purpose: steady noise above the
    // minimum reads as a voice, and the session starts streaming — exactly
    // what happened before there was a wait at all. Never hearing a quiet
    // voice would be the worse mistake.
    final d = detector();
    expect(feed(d, List.filled(5, frame(400))), isTrue);
  });

  test(
    'a quiet room learns its floor, so a hum under the minimum is ignored',
    () {
      final d = detector();
      expect(feed(d, List.filled(100, frame(90))), isFalse);
    },
  );

  test('it decides once', () {
    final d = detector();
    expect(feed(d, List.filled(3, frame(1500))), isTrue);
    expect(feed(d, List.filled(10, frame(1500))), isFalse);
  });
}
