import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// Raised on the audio stream when capture stops delivering frames without the
/// caller asking it to.
///
/// On iOS this is the only signal we get that the recorder was interrupted:
/// record's own interruption observer pauses capture and never resumes, and it
/// does not close the underlying stream, so a stalled microphone is otherwise
/// indistinguishable from silence.
class AudioSourceStalled implements Exception {
  const AudioSourceStalled(this.silentFor);

  final Duration silentFor;

  @override
  String toString() =>
      'AudioSourceStalled: no microphone frames for ${silentFor.inSeconds}s';
}

/// Raised on the audio stream when the user has not granted microphone access.
///
/// Typed, and raised on the same channel as [AudioSourceStalled], so callers
/// learn about a refusal the same way they learn about every other capture
/// failure. This class is the single owner of the permission decision: asking
/// again anywhere else races this one and answers for a different moment.
class AudioSourcePermissionDenied implements Exception {
  const AudioSourcePermissionDenied();

  @override
  String toString() =>
      'AudioSourcePermissionDenied: microphone access was refused';
}

/// Captures 16 kHz mono PCM16 audio frames from the microphone and streams
/// them to subscribers.
class AudioSource {
  final AudioRecorder _recorder;
  StreamController<Uint8List>? _controller;
  StreamSubscription<Uint8List>? _recordSubscription;

  /// Memoises an in-flight [stop] so concurrent callers share one teardown
  /// instead of racing two `AudioRecorder.stop()` calls at the platform channel.
  Future<void>? _stopping;

  Timer? _stallTimer;
  DateTime? _lastFrameAt;

  /// How long the microphone may go without delivering a frame before we treat
  /// capture as stalled. Real capture delivers frames continuously, so a gap
  /// this long means the OS took the session away.
  static const Duration stallTimeout = Duration(seconds: 3);

  AudioSource({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  /// Check microphone permission.
  Future<bool> hasPermission() async {
    return await _recorder.hasPermission();
  }

  /// Start recording audio stream.
  Stream<Uint8List> start({int sampleRate = 16000}) {
    _stopping = null;
    _controller = StreamController<Uint8List>.broadcast(onCancel: () => stop());

    _startCapture(sampleRate);
    return _controller!.stream;
  }

  /// The capture configuration, exposed so the audio-session policy is
  /// assertable — these flags are easy to drop and the symptoms (a dead mic, or
  /// silencing the user's music) only show up on a real device.
  @visibleForTesting
  static RecordConfig recordConfig(int sampleRate) => RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: sampleRate,
    numChannels: 1,
    iosConfig: const IosRecordConfig(
      // Counta plays a system click and a haptic on every tap. Without
      // this, iOS raises an AVAudioSession interruption for those sounds,
      // and record's observer responds by pausing capture permanently —
      // the microphone dies mid-session with no error.
      allowHapticsAndSystemSoundsDuringRecording: true,
      categoryOptions: [
        // Without this, activating a playAndRecord session takes the audio
        // route exclusively and stops whatever the user was listening to.
        // Counting alongside music or a podcast is a normal way to use the
        // app, so we share the route instead of seizing it.
        IosAudioCategoryOption.mixWithOthers,
        IosAudioCategoryOption.defaultToSpeaker,
        IosAudioCategoryOption.allowBluetooth,
        IosAudioCategoryOption.allowBluetoothA2DP,
        // Keeps capture alive when the mic is muted rather than ending the
        // session outright (iOS 14.5+, ignored on older versions).
        IosAudioCategoryOption.overrideMutedMicrophoneInterruption,
      ],
    ),
  );

  Future<void> _startCapture(int sampleRate) async {
    final hasPerm = await hasPermission();
    if (!hasPerm) {
      _controller?.addError(StateError('Microphone permission not granted'));
      return;
    }

    final recordStream = await _recorder.startStream(recordConfig(sampleRate));

    _lastFrameAt = DateTime.now();
    _startStallWatchdog();

    _recordSubscription = recordStream.listen(
      // recordStream is already Stream<Uint8List> and nothing mutates the
      // buffer, so copying here cost ~115 MB of memcpy per hour for nothing.
      _handleIncomingChunk,
      onError: (error, stack) {
        _controller?.addError(error, stack);
      },
      onDone: () {
        _controller?.close();
      },
    );
  }

  /// Watches for the microphone going quiet at the *frame* level.
  ///
  /// A paused iOS recorder keeps its Dart stream open but stops delivering, so
  /// there is no `onDone` and no error to react to. Surfacing this as a stream
  /// error lets the engine reconnect instead of counting silence forever.
  void _startStallWatchdog() {
    _stallTimer?.cancel();
    _stallTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final last = _lastFrameAt;
      if (last == null) return;
      if (_controller == null || _controller!.isClosed) return;

      final silentFor = DateTime.now().difference(last);
      if (silentFor >= stallTimeout) {
        _stallTimer?.cancel();
        _stallTimer = null;
        _controller?.addError(AudioSourceStalled(silentFor));
      }
    });
  }

  void _handleIncomingChunk(Uint8List chunk) {
    if (_controller == null || _controller!.isClosed) return;

    _lastFrameAt = DateTime.now();
    _controller!.add(chunk);
  }

  /// Stop audio recording.
  ///
  /// Safe to call concurrently or repeatedly: the first call owns the teardown
  /// and later callers await the same future. This matters because closing the
  /// broadcast controller fires `onCancel`, which re-enters this method.
  Future<void> stop() {
    return _stopping ??= _doStop();
  }

  Future<void> _doStop() async {
    _stallTimer?.cancel();
    _stallTimer = null;
    _lastFrameAt = null;

    final recordSubscription = _recordSubscription;
    _recordSubscription = null;
    await recordSubscription?.cancel();

    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {
      // A recorder that is already torn down is not an error worth propagating;
      // callers only need to know that capture is no longer running.
    }

    final controller = _controller;
    _controller = null;
    await controller?.close();
  }

  /// Dispose resources.
  Future<void> dispose() async {
    await stop();
    await _recorder.dispose();
  }
}
