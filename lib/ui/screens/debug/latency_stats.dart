/// Rolling summary of transcription lag samples.
///
/// A single "last result took 380 ms" reading is too noisy to judge whether
/// the pipeline feels fast, so the debug screen reports a distribution — the
/// median is what you perceive, and p95 is what makes it feel janky.
class LatencyStats {
  const LatencyStats({
    required this.count,
    required this.last,
    required this.median,
    required this.p95,
    required this.worst,
  });

  final int count;
  final Duration? last;
  final Duration? median;
  final Duration? p95;
  final Duration? worst;

  static const empty = LatencyStats(
    count: 0,
    last: null,
    median: null,
    p95: null,
    worst: null,
  );

  bool get isEmpty => count == 0;

  factory LatencyStats.from(List<Duration> samples) {
    if (samples.isEmpty) return empty;

    final sorted = [...samples]..sort();

    return LatencyStats(
      count: sorted.length,
      last: samples.last,
      median: _quantile(sorted, 0.50),
      p95: _quantile(sorted, 0.95),
      worst: sorted.last,
    );
  }

  /// Nearest-rank quantile. Exact enough for a debug read-out and avoids
  /// interpolating between two samples that were never observed.
  static Duration _quantile(List<Duration> sorted, double q) {
    final rank = (q * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
  }
}

/// Formats a lag for display, keeping millisecond precision under a second
/// because that is the range where the difference is felt.
String formatLag(Duration? lag) {
  if (lag == null) return '—';
  if (lag.inMilliseconds < 1000) return '${lag.inMilliseconds} ms';
  return '${(lag.inMilliseconds / 1000).toStringAsFixed(2)} s';
}
