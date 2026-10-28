import 'dart:math' as math;
import 'dart:typed_data';

/// Says when someone has started speaking, from raw microphone audio.
///
/// Voice counting waits for this before it buys any streaming time, so the
/// silence between pressing Start and the first word costs nothing and never
/// leaves the phone. It only ever decides *once* per wait, which shapes what
/// it gets wrong safely: firing on noise just starts streaming early, which
/// is what happened before it existed, while missing a quiet voice would
/// leave the user waiting — so it leans towards firing, and the banner keeps
/// a "Start now" for anyone it misses.
///
/// Loudness only. Speech is told from a click (a tap sound, a knock) by
/// lasting: [speechToStart] of loud audio, allowing gaps of up to
/// [gapTolerance] between syllables. Steady background noise is told from
/// speech by [aboveFloor]: the floor follows the quietest the room gets.
class VoiceActivityDetector {
  VoiceActivityDetector({
    required this.bytesPerSecond,
    this.minimumLevel = 120,
    this.aboveFloor = 3.0,
    this.speechToStart = const Duration(milliseconds: 150),
    this.gapTolerance = const Duration(milliseconds: 300),
  });

  /// PCM16 mono bytes per second of audio, to turn frame sizes into time.
  final int bytesPerSecond;

  /// RMS (of 32767) below which nothing counts as speech, whatever the room.
  /// About -49 dBFS: under a whisper close to the phone.
  final double minimumLevel;

  /// How far above the room's quietest level a frame must be.
  final double aboveFloor;

  final Duration speechToStart;
  final Duration gapTolerance;

  /// The quietest the room has been, recently. Starts low, so a voice that
  /// begins the instant capture does is still heard; falls at once to any
  /// quieter frame and creeps up slowly, so a fan switched on is learned
  /// within seconds without a voice ever teaching it.
  double _floor = 30;

  int _speechBytes = 0;
  int _quietBytes = 0;
  bool _fired = false;

  /// The level the last frame was judged at, for diagnostics.
  double lastLevel = 0;

  /// Feeds one frame of little-endian PCM16. True on the frame where speech
  /// is judged to have begun, and never again after that.
  bool add(Uint8List pcm16) {
    if (_fired || pcm16.lengthInBytes < 2) return false;

    final level = rmsOf(pcm16);
    lastLevel = level;
    final threshold = math.max(minimumLevel, _floor * aboveFloor);

    if (level >= threshold) {
      _speechBytes += pcm16.lengthInBytes;
      _quietBytes = 0;
    } else {
      _quietBytes += pcm16.lengthInBytes;
      if (_quietBytes > _bytesFor(gapTolerance)) _speechBytes = 0;
      _floor = level < _floor ? level : _floor * 1.02;
    }

    if (_speechBytes >= _bytesFor(speechToStart)) {
      _fired = true;
      return true;
    }
    return false;
  }

  int _bytesFor(Duration duration) =>
      (bytesPerSecond * duration.inMicroseconds / 1000000).round();

  /// Root-mean-square amplitude of little-endian PCM16, from 0 to 32767.
  static double rmsOf(Uint8List pcm16) {
    final samples = pcm16.lengthInBytes ~/ 2;
    if (samples == 0) return 0;
    final data = ByteData.sublistView(pcm16);
    var sum = 0.0;
    for (var i = 0; i < samples; i++) {
      final sample = data.getInt16(i * 2, Endian.little);
      sum += sample * sample;
    }
    return math.sqrt(sum / samples);
  }
}
