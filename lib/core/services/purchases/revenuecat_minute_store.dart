import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../../../domain/purchases/minute_store.dart';

/// [MinuteStore] on RevenueCat, which takes the payment through the platform
/// store and credits the `VOICE` currency the voice service spends.
///
/// The RevenueCat customer **must** be the Supabase user: that is the id the
/// voice service reads the balance of. A purchase made under any other id
/// pays for minutes nobody can spend, so every call first makes sure the SDK
/// is on the current user, rather than trusting the id it was configured
/// with — an anonymous session that had to be recreated has a new one.
class RevenueCatMinuteStore implements MinuteStore {
  RevenueCatMinuteStore({required this.apiKey, required this.currentUserId});

  final String apiKey;
  final String? Function() currentUserId;

  /// The store's own products, kept from [packs] for [buy].
  final Map<String, StoreProduct> _products = {};

  Future<void> _useCurrentUser() async {
    final userId = currentUserId();
    if (userId == null) {
      throw const MinuteStoreUnavailable(
        "Minute packs couldn't load: you're not signed in yet. Try again in "
        'a moment.',
      );
    }
    if (!await Purchases.isConfigured) {
      await Purchases.configure(
        PurchasesConfiguration(apiKey)..appUserID = userId,
      );
      return;
    }
    if (await Purchases.appUserID != userId) await Purchases.logIn(userId);
  }

  @override
  Future<List<MinutePack>> packs() async {
    final List<StoreProduct> products;
    try {
      await _useCurrentUser();
      products = await Purchases.getProducts(
        MinutePackCatalog.minutesByProduct.keys.toList(),
        // Android only, and required there: the packs are one-time products.
        productCategory: ProductCategory.nonSubscription,
      );
    } on PlatformException catch (error) {
      debugPrint('Minute packs not loaded: ${error.code} ${error.message}');
      throw const MinuteStoreUnavailable();
    }

    final packs = <MinutePack>[];
    for (final product in products) {
      final minutes = MinutePackCatalog.minutesByProduct[product.identifier];
      if (minutes == null) continue;
      _products[product.identifier] = product;
      packs.add(
        MinutePack(
          productId: product.identifier,
          minutes: minutes,
          price: product.price,
          priceLabel: product.priceString,
        ),
      );
    }
    // A product the store will not return is usually one still missing its
    // store metadata. Nothing on sale is the same as not loading.
    if (packs.isEmpty) throw const MinuteStoreUnavailable();
    packs.sort((a, b) => a.minutes.compareTo(b.minutes));
    return packs;
  }

  @override
  Future<PackPurchase> buy(MinutePack pack) async {
    final product = _products[pack.productId];
    if (product == null) {
      return const PackPurchaseFailed(
        "That pack isn't available right now. Please try again.",
      );
    }
    try {
      await _useCurrentUser();
      await Purchases.purchase(PurchaseParams.storeProduct(product));
      return const PackPurchased();
    } on MinuteStoreUnavailable catch (error) {
      return PackPurchaseFailed(error.message);
    } on PlatformException catch (error) {
      final code = PurchasesErrorHelper.getErrorCode(error);
      debugPrint('Minute pack purchase ended: $code ${error.message}');
      return switch (code) {
        PurchasesErrorCode.purchaseCancelledError =>
          const PackPurchaseCancelled(),
        PurchasesErrorCode.paymentPendingError => const PackPurchasePending(),
        PurchasesErrorCode.networkError => const PackPurchaseFailed(
          "Couldn't reach the store. Check your connection and try again.",
        ),
        PurchasesErrorCode.purchaseNotAllowedError => const PackPurchaseFailed(
          "Purchases aren't allowed on this device. Check Screen Time or "
          'your account settings.',
        ),
        PurchasesErrorCode.operationAlreadyInProgressError =>
          const PackPurchaseFailed(
            'A purchase is already in progress. Give it a moment.',
          ),
        _ => const PackPurchaseFailed(
          "The purchase didn't go through. Please try again.",
        ),
      };
    }
  }
}
