/// A pack of voice minutes on sale in the platform store.
class MinutePack {
  const MinutePack({
    required this.productId,
    required this.minutes,
    required this.price,
    required this.priceLabel,
  });

  final String productId;
  final int minutes;

  /// In the store's own currency, for comparing packs. Never shown: the store
  /// formats [priceLabel] for the buyer's locale and currency.
  final double price;
  final String priceLabel;

  double get pricePerMinute => price / minutes;
}

/// The packs the app offers, by store product id.
///
/// The minutes here are what the app *says* a pack holds. What it actually
/// grants is the `VOICE` amount associated with the product in RevenueCat,
/// so the two must agree. The ids are the same on both stores.
abstract final class MinutePackCatalog {
  static const minutesByProduct = <String, int>{
    'com.ruachtech.counta.credits.60': 60,
    'com.ruachtech.counta.credits.200': 200,
    'com.ruachtech.counta.credits.500': 500,
  };
}

/// How an attempt to buy a pack ended.
sealed class PackPurchase {
  const PackPurchase();
}

/// Paid. The minutes are granted by the store's server, not by the app.
class PackPurchased extends PackPurchase {
  const PackPurchased();
}

/// The buyer closed the store sheet. Not an error, so nothing is said.
class PackPurchaseCancelled extends PackPurchase {
  const PackPurchaseCancelled();
}

/// Waiting on someone else, such as a parent approving Ask to Buy. The
/// minutes arrive if and when it is approved.
class PackPurchasePending extends PackPurchase {
  const PackPurchasePending();

  String get message =>
      'Your purchase is waiting for approval. The minutes will appear once '
      "it's approved.";
}

/// It did not go through. [message] is written for the buyer.
class PackPurchaseFailed extends PackPurchase {
  const PackPurchaseFailed(this.message);

  final String message;
}

/// The packs could not be loaded. [message] is written for the buyer.
class MinuteStoreUnavailable implements Exception {
  const MinuteStoreUnavailable([
    this.message = "Minute packs couldn't load right now.",
  ]);

  final String message;

  @override
  String toString() => 'MinuteStoreUnavailable: $message';
}

/// Where minute packs are listed and bought: the App Store or Google Play,
/// behind whatever does the bookkeeping.
abstract class MinuteStore {
  /// The packs on sale, fewest minutes first. Throws [MinuteStoreUnavailable]
  /// when there are none to show.
  Future<List<MinutePack>> packs();

  /// Buys [pack], which must be one [packs] returned.
  Future<PackPurchase> buy(MinutePack pack);
}
