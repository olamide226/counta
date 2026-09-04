import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/services/counting/audio_source.dart';
import '../../../core/services/counting/deepgram_socket.dart';
import '../../../domain/validation/phrase_validator.dart';
import 'latency_stats.dart';
import '../../../domain/counting/speech_socket.dart';
import '../../../domain/counting/transcript_segment.dart';

class StreamingDebugScreen extends StatefulWidget {
  const StreamingDebugScreen({super.key});

  @override
  State<StreamingDebugScreen> createState() => _StreamingDebugScreenState();
}

class _StreamingDebugScreenState extends State<StreamingDebugScreen> {
  final TextEditingController _apiKeyController = TextEditingController(
    text: const String.fromEnvironment('DEEPGRAM_API_KEY'),
  );
  final TextEditingController _phraseController = TextEditingController(
    text: "I'm rich in wisdom",
  );

  /// Fixture identity, written into the export so the file lands ready to
  /// commit under test/fixtures/transcripts/ with no hand-editing.
  final TextEditingController _fixtureNameController = TextEditingController(
    text: 'normal_100',
  );
  final TextEditingController _trueCountController = TextEditingController(
    text: '100',
  );

  AudioSource? _audioSource;
  SpeechSocket? _speechSocket;
  StreamSubscription<Uint8List>? _audioSubscription;
  StreamSubscription<TranscriptSegment>? _segmentSubscription;
  StreamSubscription<SocketState>? _stateSubscription;

  bool _isStreaming = false;
  SocketState _socketState = SocketState.disconnected;
  final List<TranscriptSegment> _segments = [];
  final List<TranscriptSegment> _interimSegments = [];
  String? _lastExportPath;

  /// The in-flight interim result, shown in place rather than appended. Every
  /// interim used to become another row, which buried new text below the fold
  /// and made a fast pipeline look slow.
  TranscriptSegment? _liveInterim;

  final List<Duration> _interimLags = [];
  final List<Duration> _finalLags = [];
  Duration? _timeToFirstResult;
  DateTime? _streamStartedAt;
  int _audioBytesSent = 0;

  /// Most recent samples only. Deepgram emits ~5 interims/sec, so an
  /// unbounded list reached tens of thousands of entries within an hour — and
  /// every rebuild sorted all of them.
  static const int _maxLagSamples = 500;
  static const int _maxExportedInterimSegments = 10000;

  LatencyStats _interimStats = LatencyStats.empty;
  LatencyStats _finalStats = LatencyStats.empty;

  Map<String, dynamic> _statsToJson(LatencyStats stats) => {
    'count': stats.count,
    'last_ms': stats.last?.inMilliseconds,
    'median_ms': stats.median?.inMilliseconds,
    'p95_ms': stats.p95?.inMilliseconds,
    'worst_ms': stats.worst?.inMilliseconds,
  };

  void _recordSegment(TranscriptSegment segment) {
    _timeToFirstResult ??= DateTime.now().difference(_streamStartedAt!);

    final lag = segment.lag;
    if (lag != null) {
      final samples = segment.isFinal ? _finalLags : _interimLags;
      samples.add(lag);
      if (samples.length > _maxLagSamples) samples.removeAt(0);

      // Computed here rather than in build(): this runs once per segment,
      // build runs far more often.
      final stats = LatencyStats.from(samples);
      if (segment.isFinal) {
        _finalStats = stats;
      } else {
        _interimStats = stats;
      }
    }

    if (segment.isFinal) {
      _segments.add(segment);
      _liveInterim = null;
    } else {
      if (segment.text.trim().isNotEmpty) {
        _interimSegments.add(segment);
        if (_interimSegments.length > _maxExportedInterimSegments) {
          _interimSegments.removeAt(0);
        }
      }
      _liveInterim = segment;
    }
  }

  @override
  void dispose() {
    // Not _stopStreaming(): that calls setState, which is illegal here.
    _teardown();
    _apiKeyController.dispose();
    _phraseController.dispose();
    _fixtureNameController.dispose();
    _trueCountController.dispose();
    super.dispose();
  }

  Future<void> _startStreaming() async {
    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a Deepgram API key')),
      );
      return;
    }

    setState(() {
      _segments.clear();
      _interimSegments.clear();
      _liveInterim = null;
      _interimLags.clear();
      _finalLags.clear();
      _interimStats = LatencyStats.empty;
      _finalStats = LatencyStats.empty;
      _timeToFirstResult = null;
      _audioBytesSent = 0;
      _streamStartedAt = DateTime.now();
      _isStreaming = true;
    });

    _audioSource = AudioSource();
    _speechSocket = DeepgramSocket();

    _stateSubscription = _speechSocket!.state.listen((state) {
      if (mounted) {
        setState(() {
          _socketState = state;
        });
      }
    });

    _segmentSubscription = _speechSocket!.segments.listen((segment) {
      if (mounted) {
        setState(() => _recordSegment(segment));
      }
    });

    // Use the production validator, not a local copy of the tokeniser: this
    // screen exists to measure real matcher behaviour, so it must normalise
    // the phrase exactly the way a real session does.
    final validation = PhraseValidator().validate(_phraseController.text);
    final phrase = validation.phraseSpec;
    if (phrase == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(validation.errorMessage ?? 'Invalid phrase')),
      );
      await _stopStreaming();
      return;
    }

    try {
      await _speechSocket!.connect(apiKeyOrToken: apiKey, phrase: phrase);

      final audioStream = _audioSource!.start();
      _audioSubscription = audioStream.listen(
        (data) {
          _speechSocket?.sendAudio(data);
          _audioBytesSent += data.length;
        },
        onError: (Object e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Audio error: $e')));
          }
        },
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Connection failed: $e')));
        _stopStreaming();
      }
    }
  }

  Future<void> _stopStreaming() async {
    // Flip the flag first so the button reflects the user's intent immediately
    // and cannot be pressed again while teardown is in flight.
    if (mounted) {
      setState(() => _isStreaming = false);
    }

    await _teardown();

    if (mounted) {
      setState(() => _socketState = SocketState.disconnected);
    }
  }

  /// Releases the microphone and socket. Never throws, so callers can always
  /// reach their own state updates.
  Future<void> _teardown() async {
    final audioSubscription = _audioSubscription;
    final audioSource = _audioSource;
    final speechSocket = _speechSocket;
    final segmentSubscription = _segmentSubscription;
    final stateSubscription = _stateSubscription;

    _audioSubscription = null;
    _audioSource = null;
    _speechSocket = null;
    _segmentSubscription = null;
    _stateSubscription = null;

    try {
      await audioSubscription?.cancel();
      await audioSource?.stop();

      if (speechSocket != null) {
        await speechSocket.closeGracefully();
        await segmentSubscription?.cancel();
        await stateSubscription?.cancel();
        await speechSocket.dispose();
      }
    } catch (e) {
      debugPrint('Streaming teardown failed: $e');
    }
  }

  Future<void> _exportTranscriptFixture() async {
    if (_segments.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No transcript segments to export')),
      );
      return;
    }

    final trueCount = int.tryParse(_trueCountController.text.trim());
    if (trueCount == null || trueCount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter the true count before exporting a fixture'),
        ),
      );
      return;
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      final name = _fixtureNameController.text.trim().isEmpty
          ? 'fixture'
          : _fixtureNameController.text.trim().replaceAll(
              RegExp(r'[^A-Za-z0-9_-]'),
              '_',
            );
      final file = File('${dir.path}/$name.json');

      final jsonContent = const JsonEncoder.withIndent('  ').convert({
        'exported_at': DateTime.now().toIso8601String(),
        'fixture_name': name,
        'phrase_raw': _phraseController.text,
        // Read by FixtureReplayHarness to compute recall. Recorded here so the
        // file is committable as-is, rather than hand-labelled afterwards.
        'true_count': trueCount,
        'segment_count': _segments.length,
        'interim_segment_count': _interimSegments.length,
        'latency': {
          'time_to_first_result_ms': _timeToFirstResult?.inMilliseconds,
          'interim': _statsToJson(_interimStats),
          'final': _statsToJson(_finalStats),
        },
        'segments': _segments.map((s) => s.toJson()).toList(),
        'interim_segments': _interimSegments.map((s) => s.toJson()).toList(),
      });

      await file.writeAsString(jsonContent);

      setState(() {
        _lastExportPath = file.path;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved fixture to ${file.path}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save export: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Streaming Spike Debug'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Export Transcript Fixture JSON',
            onPressed: _segments.isNotEmpty ? _exportTranscriptFixture : null,
          ),
        ],
      ),
      // A CustomScrollView, not a Column: the controls plus the latency panel
      // are taller than a phone viewport once the keyboard is up, and a fixed
      // Column has nowhere to put the excess. The transcript list stays a
      // sliver so it is still built lazily.
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(16.0),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  TextField(
                    controller: _apiKeyController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Deepgram API Key (Debug only)',
                      border: OutlineInputBorder(),
                      hintText: 'Enter API key for streaming test',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _phraseController,
                    decoration: const InputDecoration(
                      labelText: 'Target Phrase',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _fixtureNameController,
                          decoration: const InputDecoration(
                            labelText: 'Fixture name',
                            helperText: 'becomes the filename',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _trueCountController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'True count',
                            helperText: 'reps you chanted',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Wrap, not Row: the status chip grows with the state name
                  // ("disconnected" is the longest) and together with the
                  // button it does not fit a narrow phone on one line.
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Chip(
                        label: Text(
                          'Status: ${_socketState.name}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        backgroundColor: _socketState == SocketState.connected
                            ? Colors.green.shade100
                            : Colors.grey.shade200,
                      ),
                      ElevatedButton.icon(
                        onPressed: _isStreaming
                            ? _stopStreaming
                            : _startStreaming,
                        icon: Icon(_isStreaming ? Icons.stop : Icons.mic),
                        label: Text(
                          _isStreaming ? 'Stop Streaming' : 'Start Streaming',
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isStreaming
                              ? Colors.red
                              : Colors.green,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_lastExportPath != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Text(
                        'Last Export: $_lastExportPath',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                  _buildLatencyPanel(),
                  const SizedBox(height: 12),
                  _buildLiveInterim(),
                  const SizedBox(height: 12),
                  const Text(
                    'Final transcripts (newest first):',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                ]),
              ),
            ),
            if (_segments.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
                  child: Center(child: Text('No final transcripts yet')),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                sliver: SliverList.builder(
                  itemCount: _segments.length,
                  itemBuilder: (context, index) {
                    // Newest first: appending to the bottom meant new results
                    // landed off-screen, which read as the pipeline being slow
                    // when it was not.
                    final seg = _segments[_segments.length - 1 - index];
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        dense: true,
                        title: Text(
                          seg.text,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          'lag: ${formatLag(seg.lag)} | '
                          'confidence: ${(seg.confidence * 100).toStringAsFixed(1)}% | '
                          'audio: ${seg.start.toStringAsFixed(2)}\u2013'
                          '${seg.endOffset.toStringAsFixed(2)}s',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: _LagBadge(lag: seg.lag),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The headline read-out: how far behind live the transcript is running.
  Widget _buildLatencyPanel() {
    final theme = Theme.of(context);
    final interim = _interimStats;
    final finals = _finalStats;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.speed_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Transcription lag',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text(
                '${_audioBytesSent ~/ 1024} KB sent',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Time from you speaking to the text arriving — '
            'covers capture, network and Deepgram.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          _LatencyRow(label: 'Interim', stats: interim),
          const SizedBox(height: 6),
          _LatencyRow(label: 'Final', stats: finals),
          const SizedBox(height: 8),
          Text(
            'First result after start: ${formatLag(_timeToFirstResult)}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveInterim() {
    final theme = Theme.of(context);
    final interim = _liveInterim;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            interim == null ? Icons.hearing_disabled : Icons.hearing,
            size: 18,
            color: theme.colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              interim?.text ?? 'Listening…',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontStyle: interim == null ? FontStyle.italic : null,
              ),
            ),
          ),
          if (interim != null) _LagBadge(lag: interim.lag),
        ],
      ),
    );
  }
}

class _LatencyRow extends StatelessWidget {
  const _LatencyRow({required this.label, required this.stats});

  final String label;
  final LatencyStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final valueStyle = theme.textTheme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
      fontWeight: FontWeight.w600,
    );

    Widget cell(String name, Duration? value) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name,
            style: labelStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            formatLag(value),
            style: valueStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );

    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(
            '$label (${stats.count})',
            style: labelStyle?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        cell('last', stats.last),
        cell('median', stats.median),
        cell('p95', stats.p95),
        cell('worst', stats.worst),
      ],
    );
  }
}

/// Colour-codes a lag so the read-out is scannable without doing arithmetic.
class _LagBadge extends StatelessWidget {
  const _LagBadge({required this.lag});

  final Duration? lag;

  @override
  Widget build(BuildContext context) {
    if (lag == null) return const SizedBox.shrink();

    final ms = lag!.inMilliseconds;
    final scheme = Theme.of(context).colorScheme;
    // Under ~500 ms reads as conversational; beyond ~1.2 s feels laggy.
    final color = ms < 500
        ? Colors.green
        : ms < 1200
        ? Colors.orange
        : scheme.error;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        formatLag(lag),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: color,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
