/// The app's one date-and-time format, `d/m/yyyy hh:mm`.
///
/// Three screens had byte-identical private copies of this, which is three
/// places to change when the format does.
extension SessionDateFormat on DateTime {
  String get asSessionTimestamp {
    final hh = hour.toString().padLeft(2, '0');
    final mm = minute.toString().padLeft(2, '0');
    return '$day/$month/$year $hh:$mm';
  }
}
