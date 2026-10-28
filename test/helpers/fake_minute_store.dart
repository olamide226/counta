import 'package:counta/domain/purchases/minute_store.dart';

import 'voice_fakes.dart';

/// A [MinuteStore] that sells from a fixed price list and, on a purchase,
/// credits [credits] the way RevenueCat credits the voice service.
class FakeMinuteStore implements MinuteStore {
  FakeMinuteStore({
    this.credits,
    this.prices = const {
      'com.ruachtech.counta.credits.60': 4.99,
      'com.ruachtech.counta.credits.200': 9.99,
      'com.ruachtech.counta.credits.500': 19.99,
    },
    this.packsFailure,
  });

  /// Where a successful purchase lands. Null credits nothing, which is a
  /// purchase the server has not caught up with.
  final FakeBlockService? credits;
  final Map<String, double> prices;
  MinuteStoreUnavailable? packsFailure;

  /// What the next [buy] answers. Null is a completed purchase.
  PackPurchase? nextOutcome;
  final List<String> bought = [];

  @override
  Future<List<MinutePack>> packs() async {
    final failure = packsFailure;
    if (failure != null) throw failure;
    return [
      for (final entry in prices.entries)
        MinutePack(
          productId: entry.key,
          minutes: MinutePackCatalog.minutesByProduct[entry.key]!,
          price: entry.value,
          priceLabel: '\$${entry.value.toStringAsFixed(2)}',
        ),
    ]..sort((a, b) => a.minutes.compareTo(b.minutes));
  }

  @override
  Future<PackPurchase> buy(MinutePack pack) async {
    bought.add(pack.productId);
    final outcome = nextOutcome ?? const PackPurchased();
    nextOutcome = null;
    if (outcome is PackPurchased) credits?.balance += pack.minutes;
    return outcome;
  }
}
