import 'package:flutter_riverpod/flutter_riverpod.dart';

const double kDefaultTapZoneRatio = 0.75;
const double kMinTapZoneRatio = 0.2;
const double kMaxTapZoneRatio = 0.9;

final tapZoneRatioProvider = StateProvider<double>(
  (ref) => kDefaultTapZoneRatio,
);
