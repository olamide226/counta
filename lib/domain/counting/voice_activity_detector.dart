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
/// Loudness only, judged in [window]-long slices rather than per microphone
/// frame. iOS hands audio over in chunks of around 100 ms, and judging a
/// whole chunk let one knock on a table make all of it "loud": a knock and
/// its echo were enough to start a session. Speech is told from a knock by
/// staying loud: at least [speechToStart] of loud slices within the last
/// [lookBack]. A voice holds that through a syllable; a knock is loud for a
/// slice or two and gone.
///
/// "Loud" is above both [minimumLevel] and [aboveFloor] times the room's
/// quietest recent level, so a steady hum is learned rather than heard.
class VoiceActivityDetector {
  VoiceActivityDetector({
    required this.bytesPerSecond,
    this.minimumLevel = 120,
    this.aboveFloor = 3.0,
    this.window = const Duration(milliseconds: 20),
    this.speechToStart = const Duration(milliseconds: 160),
    this.lookBack = const Duration(milliseconds: 300),
  });

  /// PCM16 mono bytes per second of audio, to turn sizes into time.
  final int bytesPerSecond;

  /// RMS (of 32767) below which nothing counts as speech, whatever the room.
  /// About -49 dBFS: under a soft voice close to the phone. On a real phone,
  /// quiet speech first registered at 151 and 252, ordinary speech at
  /// 1100–1900.
  final double minimumLevel;

  /// How far above the room's quietest level a slice must be.
  final double aboveFloor;

  /// The slice audio is judged in.
  final Duration window;

  /// Loud audio needed, within [lookBack], to call it a voice.
  final Duration speechToStart;
  final Duration lookBack;

  /// The quietest the room has been, recently. Starts low, so a voice that
  /// begins the instant capture does is still heard; falls at once to any
  /// quieter slice and creeps up slowly, so a fan switched on is learned
  /// within seconds without a voice ever teaching it.
  double _floor = 30;

  /// Whether each of the last few slices was loud, newest last.
  final List<bool> _recent = [];

  /// Bytes left over from the last frame, short of a whole slice.
  final BytesBuilder _carry = BytesBuilder(copy: false);

  bool _fired = false;

  /// The loudest slice that counted towards the decision, for diagnostics.
  double lastLevel = 0;

  int get _windowBytes =>
      math.max(2, (bytesPerSecond * _seconds(window)).round() & ~1);
  int get _lookBackSlices => (_seconds(lookBack) / _seconds(window)).round();
  int get _slicesToStart => (_seconds(speechToStart) / _seconds(window)).ceil();

  static double _seconds(Duration d) => d.inMicroseconds / 1000000;

  /// Feeds one frame of little-endian PCM16, of any length. True on the
  /// frame where speech is judged to have begun, and never again after that.
  bool add(Uint8List pcm16) {
    if (_fired) return false;
    _carry.add(pcm16);
    final bytes = _carry.takeBytes();
    final size = _windowBytes;

    var offset = 0;
    while (bytes.length - offset >= size) {
      if (_judge(Uint8List.sublistView(bytes, offset, offset + size))) {
        _fired = true;
        return true;
      }
      offset += size;
    }
    if (offset < bytes.length) {
      _carry.add(Uint8List.sublistView(bytes, offset));
    }
    return false;
  }

  bool _judge(Uint8List slice) {
    final level = rmsOf(slice);
    final loud = level >= math.max(minimumLevel, _floor * aboveFloor);
    if (loud) {
      lastLevel = math.max(lastLevel, level);
    } else {
      _floor = level < _floor ? level : _floor * 1.004;
    }

    _recent.add(loud);
    if (_recent.length > _lookBackSlices) _recent.removeAt(0);
    if (_recent.where((s) => s).length >= _slicesToStart) return true;
    if (_recent.every((s) => !s)) lastLevel = 0;
    return false;
  }

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
