/// Represents an individual word in a transcript segment from Deepgram.
class TranscriptWord {
  final String word;
  final double start;
  final double end;
  final double confidence;

  const TranscriptWord({
    required this.word,
    required this.start,
    required this.end,
    required this.confidence,
  });

  Map<String, dynamic> toJson() => {
        'word': word,
        'start': start,
        'end': end,
        'confidence': confidence,
      };

  factory TranscriptWord.fromJson(Map<String, dynamic> json) => TranscriptWord(
        word: json['word'] as String? ?? '',
        start: (json['start'] as num?)?.toDouble() ?? 0.0,
        end: (json['end'] as num?)?.toDouble() ?? 0.0,
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      );
}

/// Represents a transcript segment emitted by Deepgram.
class TranscriptSegment {
  final String text;
  final double start;
  final double duration;
  final bool isFinal;
  final double confidence;
  final bool speechFinal;
  final List<TranscriptWord> words;
  final DateTime receivedAt;

  /// How far behind live audio this result arrived.
  ///
  /// Measured as wall-clock time since audio started, minus the audio-timeline
  /// position of the end of the transcribed span ([start] + [duration]). It
  /// therefore covers the whole round trip — capture, upload, recognition and
  /// delivery — which is what "how fast does it feel" actually means.
  ///
  /// Null when the socket had not started streaming audio yet.
  final Duration? lag;

  /// Audio-timeline position of the end of this segment, in seconds.
  double get endOffset => start + duration;

  TranscriptSegment({
    required this.text,
    required this.start,
    required this.duration,
    required this.isFinal,
    required this.confidence,
    this.speechFinal = false,
    this.words = const [],
    this.lag,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  TranscriptSegment copyWith({Duration? lag}) => TranscriptSegment(
        text: text,
        start: start,
        duration: duration,
        isFinal: isFinal,
        confidence: confidence,
        speechFinal: speechFinal,
        words: words,
        lag: lag ?? this.lag,
        receivedAt: receivedAt,
      );

  Map<String, dynamic> toJson() => {
        'text': text,
        'start': start,
        'duration': duration,
        'is_final': isFinal,
        'confidence': confidence,
        'speech_final': speechFinal,
        'words': words.map((w) => w.toJson()).toList(),
        'received_at': receivedAt.toIso8601String(),
        'lag_ms': lag?.inMilliseconds,
      };

  factory TranscriptSegment.fromJson(Map<String, dynamic> json) {
    final wordsList = (json['words'] as List<dynamic>?)
            ?.map((w) => TranscriptWord.fromJson(w as Map<String, dynamic>))
            .toList() ??
        [];

    return TranscriptSegment(
      text: json['text'] as String? ?? '',
      start: (json['start'] as num?)?.toDouble() ?? 0.0,
      duration: (json['duration'] as num?)?.toDouble() ?? 0.0,
      isFinal: json['is_final'] as bool? ?? false,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      speechFinal: json['speech_final'] as bool? ?? false,
      words: wordsList,
      receivedAt: json['received_at'] != null
          ? DateTime.tryParse(json['received_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  /// Helper factory to parse from Deepgram raw WebSocket message JSON map
  factory TranscriptSegment.fromDeepgramJson(Map<String, dynamic> json) {
    final isFinal = json['is_final'] as bool? ?? false;
    final speechFinal = json['speech_final'] as bool? ?? false;
    final channel = json['channel'] as Map<String, dynamic>?;
    final alternatives = channel?['alternatives'] as List<dynamic>?;

    if (alternatives == null || alternatives.isEmpty) {
      return TranscriptSegment(
        text: '',
        start: 0.0,
        duration: 0.0,
        isFinal: isFinal,
        confidence: 0.0,
        speechFinal: speechFinal,
      );
    }

    final primaryAlt = alternatives.first as Map<String, dynamic>;
    final text = primaryAlt['transcript'] as String? ?? '';
    final confidence = (primaryAlt['confidence'] as num?)?.toDouble() ?? 0.0;
    final start = (json['start'] as num?)?.toDouble() ?? 0.0;
    final duration = (json['duration'] as num?)?.toDouble() ?? 0.0;

    // Only finals carry word-level data anywhere: PhraseMatcher drops interim
    // segments before reading `words`, and the debug UI shows text only. At ~5
    // interims/sec, parsing them anyway burned hundreds of thousands of
    // throwaway objects per session.
    final rawWords =
        isFinal ? primaryAlt['words'] as List<dynamic>? ?? const [] : const [];
    final words = rawWords
        .map((w) => TranscriptWord.fromJson(w as Map<String, dynamic>))
        .toList();

    return TranscriptSegment(
      text: text,
      start: start,
      duration: duration,
      isFinal: isFinal,
      confidence: confidence,
      speechFinal: speechFinal,
      words: words,
    );
  }
}
