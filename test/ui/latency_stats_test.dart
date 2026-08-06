import 'package:flutter_test/flutter_test.dart';

import 'package:counta/ui/screens/debug/latency_stats.dart';

Duration ms(int value) => Duration(milliseconds: value);

void main() {
  group('LatencyStats', () {
    test('is empty with no samples', () {
      final stats = LatencyStats.from(const []);

      expect(stats.isEmpty, isTrue);
      expect(stats.count, 0);
      expect(stats.median, isNull);
      expect(stats.p95, isNull);
    });

    test('reports last in arrival order, not sorted order', () {
      // The most recent reading is what the user just felt, so it must not be
      // reordered by the sort used for the quantiles.
      final stats = LatencyStats.from([ms(900), ms(120), ms(300)]);

      expect(stats.last, ms(300));
      expect(stats.worst, ms(900));
    });

    test('computes nearest-rank quantiles', () {
      final samples = [
        for (var i = 1; i <= 100; i++) ms(i * 10),
      ]..shuffle();

      final stats = LatencyStats.from(samples);

      expect(stats.count, 100);
      expect(stats.median, ms(500));
      expect(stats.p95, ms(950));
      expect(stats.worst, ms(1000));
    });

    test('handles a single sample without dividing by zero', () {
      final stats = LatencyStats.from([ms(250)]);

      expect(stats.count, 1);
      expect(stats.last, ms(250));
      expect(stats.median, ms(250));
      expect(stats.p95, ms(250));
      expect(stats.worst, ms(250));
    });

    test('does not mutate the caller\'s list', () {
      final samples = [ms(900), ms(100)];
      LatencyStats.from(samples);

      expect(samples, [ms(900), ms(100)]);
    });
  });

  group('formatLag', () {
    test('shows milliseconds below a second', () {
      expect(formatLag(ms(0)), '0 ms');
      expect(formatLag(ms(487)), '487 ms');
      expect(formatLag(ms(999)), '999 ms');
    });

    test('switches to seconds at and above a second', () {
      expect(formatLag(ms(1000)), '1.00 s');
      expect(formatLag(ms(2340)), '2.34 s');
    });

    test('renders a dash when there is no sample', () {
      expect(formatLag(null), '—');
    });
  });
}
