/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../models/market_shop.dart';
import '../models/market_item.dart';
import '../models/market_cart.dart';
import '../models/market_order.dart';
import '../models/market_review.dart';
import '../models/market_promotion.dart';
import '../models/market_coupon.dart';
import 'log_service.dart';

/// Service for managing marketplace operations
class MarketService {
  static final MarketService _instance = MarketService._internal();
  factory MarketService() => _instance;
  MarketService._internal();

  String? _collectionPath;
  MarketShop? _shop;

  /// Initialize market service for a collection
  Future<void> initializeCollection(String collectionPath, {String? creatorNpub}) async {
    LogService().log('MarketService: Initializing with collection path: $collectionPath');
    _collectionPath = collectionPath;

    // Ensure shop directory exists
    final shopDir = Directory('$collectionPath/shop');
    if (!await shopDir.exists()) {
      await shopDir.create(recursive: true);
      LogService().log('MarketService: Created shop directory');
    }

    // Load shop
    await _loadShop();

    // If shop doesn't exist and creator provided, initialize new shop
    if (_shop == null && creatorNpub != null && creatorNpub.isNotEmpty) {
      LogService().log('MarketService: Creating new shop for creator: $creatorNpub');
      // Shop will be created when user fills in shop details
    }
  }

  /// Load shop from file
  Future<void> _loadShop() async {
    if (_collectionPath == null) return;

    final shopFile = File('$_collectionPath/shop/shop.txt');
    if (await shopFile.exists()) {
      try {
        final content = await shopFile.readAsString();
        _shop = MarketShop.fromText(content);
        LogService().log('MarketService: Loaded shop: ${_shop!.shopName}');
      } catch (e) {
        LogService().log('MarketService: Error loading shop: $e');
        _shop = null;
      }
    } else {
      _shop = null;
    }
  }

  /// Get current shop
  MarketShop? getShop() => _shop;

  /// Save shop
  Future<void> saveShop(MarketShop shop) async {
    if (_collectionPath == null) return;

    _shop = shop;

    final shopFile = File('$_collectionPath/shop/shop.txt');
    await shopFile.writeAsString(shop.exportAsText(), flush: true);

    LogService().log('MarketService: Saved shop: ${shop.shopName}');
  }

  // ============================================================================
  // ITEMS
  // ============================================================================

  /// Get all item categories (from folder structure)
  Future<List<String>> getCategories() async {
    if (_collectionPath == null) return [];

    final itemsDir = Directory('$_collectionPath/shop/items');
    if (!await itemsDir.exists()) return [];

    final categories = <String>[];
    // Use toList() to collect all entities first, then close the stream
    final entities = await itemsDir.list(recursive: true).toList();

    for (var entity in entities) {
      if (entity is Directory) {
        // Get relative path from items directory
        final relativePath = entity.path.replaceFirst('${itemsDir.path}/', '');
        // Skip item directories (they start with "item-")
        if (!relativePath.contains('/item-') && !relativePath.startsWith('item-')) {
          categories.add(relativePath);
        }
      }
    }

    categories.sort();
    return categories;
  }

  /// Load all items
  Future<List<MarketItem>> loadItems({String? category}) async {
    if (_collectionPath == null) return [];

    final itemsDir = Directory('$_collectionPath/shop/items');
    if (!await itemsDir.exists()) return [];

    final items = <MarketItem>[];

    // If category specified, search within that category folder
    final searchDir = category != null
        ? Directory('${itemsDir.path}/$category')
        : itemsDir;

    if (!await searchDir.exists()) return [];

    // Use toList() to collect all entities first, then close the stream
    final entities = await searchDir.list(recursive: true).toList();

    for (var entity in entities) {
      if (entity is File && entity.path.endsWith('/item.txt')) {
        try {
          final content = await entity.readAsString();
          final itemDir = Directory(entity.parent.path);
          final itemId = itemDir.path.split('/').last;

          // Get category path (relative to items directory)
          String? categoryPath;
          final relativePath = itemDir.path.replaceFirst('${itemsDir.path}/', '');
          final parts = relativePath.split('/');
          if (parts.length > 1) {
            categoryPath = parts.sublist(0, parts.length - 1).join('/');
          }

          final item = MarketItem.fromText(content, itemId, categoryPath: categoryPath);
          items.add(item);
        } catch (e) {
          LogService().log('MarketService: Error loading item from ${entity.path}: $e');
        }
      }
    }

    // Sort by updated date (most recent first)
    items.sort((a, b) => b.updatedDate.compareTo(a.updatedDate));

    return items;
  }

  /// Load single item
  Future<MarketItem?> loadItem(String itemId, {String? categoryPath}) async {
    if (_collectionPath == null) return null;

    // Search for item in all categories if not specified
    if (categoryPath == null) {
      final allItems = await loadItems();
      return allItems.firstWhere(
        (item) => item.itemId == itemId,
        orElse: () => throw Exception('Item not found'),
      );
    }

    final itemFile = File('$_collectionPath/shop/items/$categoryPath/$itemId/item.txt');
    if (!await itemFile.exists()) return null;

    try {
      final content = await itemFile.readAsString();
      return MarketItem.fromText(content, itemId, categoryPath: categoryPath);
    } catch (e) {
      LogService().log('MarketService: Error loading item $itemId: $e');
      return null;
    }
  }

  /// Save item
  Future<void> saveItem(MarketItem item) async {
    if (_collectionPath == null) return;

    final categoryPath = item.categoryPath ?? 'uncategorized';
    final itemDir = Directory('$_collectionPath/shop/items/$categoryPath/${item.itemId}');

    if (!await itemDir.exists()) {
      await itemDir.create(recursive: true);
    }

    final itemFile = File('${itemDir.path}/item.txt');
    await itemFile.writeAsString(item.exportAsText(), flush: true);

    LogService().log('MarketService: Saved item: ${item.itemId}');
  }

  /// Delete item
  Future<void> deleteItem(String itemId, {String? categoryPath}) async {
    if (_collectionPath == null) return;

    if (categoryPath == null) {
      // Find item in all categories
      final allItems = await loadItems();
      final item = allItems.firstWhere(
        (i) => i.itemId == itemId,
        orElse: () => throw Exception('Item not found'),
      );
      categoryPath = item.categoryPath ?? 'uncategorized';
    }

    final itemDir = Directory('$_collectionPath/shop/items/$categoryPath/$itemId');
    if (await itemDir.exists()) {
      await itemDir.delete(recursive: true);
      LogService().log('MarketService: Deleted item: $itemId');
    }
  }

  // ============================================================================
  // REVIEWS
  // ============================================================================

  /// Load reviews for an item
  Future<List<MarketReview>> loadReviews(String itemId, {String? categoryPath}) async {
    if (_collectionPath == null) return [];

    if (categoryPath == null) {
      final allItems = await loadItems();
      final item = allItems.firstWhere(
        (i) => i.itemId == itemId,
        orElse: () => throw Exception('Item not found'),
      );
      categoryPath = item.categoryPath ?? 'uncategorized';
    }

    final reviewsDir = Directory('$_collectionPath/shop/items/$categoryPath/$itemId/reviews');
    if (!await reviewsDir.exists()) return [];

    final reviews = <MarketReview>[];

    // Use toList() to collect all entities first, then close the stream
    final entities = await reviewsDir.list().toList();

    for (var entity in entities) {
      if (entity is File && entity.path.endsWith('.txt')) {
        try {
          final content = await entity.readAsString();
          final review = MarketReview.fromText(content);
          reviews.add(review);
        } catch (e) {
          LogService().log('MarketService: Error loading review from ${entity.path}: $e');
        }
      }
    }

    // Sort by created date (most recent first)
    reviews.sort((a, b) => b.dateTime.compareTo(a.dateTime));

    return reviews;
  }

  /// Save review
  Future<void> saveReview(MarketReview review, {String? categoryPath}) async {
    if (_collectionPath == null) return;

    if (categoryPath == null) {
      final allItems = await loadItems();
      final item = allItems.firstWhere(
        (i) => i.itemId == review.itemId,
        orElse: () => throw Exception('Item not found'),
      );
      categoryPath = item.categoryPath ?? 'uncategorized';
    }

    final reviewsDir = Directory('$_collectionPath/shop/items/$categoryPath/${review.itemId}/reviews');
    if (!await reviewsDir.exists()) {
      await reviewsDir.create(recursive: true);
    }

    final reviewFile = File('${reviewsDir.path}/review-${review.reviewer}.txt');
    await reviewFile.writeAsString(review.exportAsText(), flush: true);

    LogService().log('MarketService: Saved review for item ${review.itemId}');
  }

  // ============================================================================
  // CARTS
  // ============================================================================

  /// Load cart for buyer
  Future<MarketCart?> loadCart(String buyerCallsign) async {
    if (_collectionPath == null) return null;

    final cartsDir = Directory('$_collectionPath/carts');
    if (!await cartsDir.exists()) return null;

    // Find cart file for buyer
    final entities = await cartsDir.list().toList();
    for (var entity in entities) {
      if (entity is File && entity.path.contains('cart-$buyerCallsign')) {
        try {
          final content = await entity.readAsString();
          return MarketCart.fromText(content);
        } catch (e) {
          LogService().log('MarketService: Error loading cart: $e');
          return null;
        }
      }
    }

    return null;
  }

  /// Save cart
  Future<void> saveCart(MarketCart cart) async {
    if (_collectionPath == null) return;

    final cartsDir = Directory('$_collectionPath/carts');
    if (!await cartsDir.exists()) {
      await cartsDir.create(recursive: true);
    }

    final cartFile = File('${cartsDir.path}/${cart.cartId}.txt');
    await cartFile.writeAsString(cart.exportAsText(), flush: true);

    LogService().log('MarketService: Saved cart: ${cart.cartId}');
  }

  // ============================================================================
  // ORDERS
  // ============================================================================

  /// Load all orders
  Future<List<MarketOrder>> loadOrders({int? year}) async {
    if (_collectionPath == null) return [];

    final ordersDir = Directory('$_collectionPath/orders');
    if (!await ordersDir.exists()) return [];

    final orders = <MarketOrder>[];

    if (year != null) {
      // Load orders from specific year
      final yearDir = Directory('${ordersDir.path}/$year');
      if (await yearDir.exists()) {
        await _loadOrdersFromDir(yearDir, orders);
      }
    } else {
      // Load orders from all years
      final entities = await ordersDir.list().toList();
      for (var entity in entities) {
        if (entity is Directory) {
          await _loadOrdersFromDir(Directory(entity.path), orders);
        }
      }
    }

    // Sort by created date (most recent first)
    orders.sort((a, b) => b.createdDate.compareTo(a.createdDate));

    return orders;
  }

  Future<void> _loadOrdersFromDir(Directory dir, List<MarketOrder> orders) async {
    final entities = await dir.list().toList();
    for (var entity in entities) {
      if (entity is File && entity.path.endsWith('.txt')) {
        try {
          final content = await entity.readAsString();
          final order = MarketOrder.fromText(content);
          orders.add(order);
        } catch (e) {
          LogService().log('MarketService: Error loading order from ${entity.path}: $e');
        }
      }
    }
  }

  /// Load single order
  Future<MarketOrder?> loadOrder(String orderId) async {
    final orders = await loadOrders();
    try {
      return orders.firstWhere((o) => o.orderId == orderId);
    } catch (e) {
      return null;
    }
  }

  /// Save order
  Future<void> saveOrder(MarketOrder order) async {
    if (_collectionPath == null) return;

    final year = order.createdDate.year;
    final yearDir = Directory('$_collectionPath/orders/$year');

    if (!await yearDir.exists()) {
      await yearDir.create(recursive: true);
    }

    final orderFile = File('${yearDir.path}/${order.orderId}.txt');
    await orderFile.writeAsString(order.exportAsText(), flush: true);

    LogService().log('MarketService: Saved order: ${order.orderId}');
  }

  // ============================================================================
  // PROMOTIONS
  // ============================================================================

  /// Load all promotions
  Future<List<MarketPromotion>> loadPromotions() async {
    if (_collectionPath == null) return [];

    final promosDir = Directory('$_collectionPath/shop/promotions');
    if (!await promosDir.exists()) return [];

    final promotions = <MarketPromotion>[];

    final entities = await promosDir.list().toList();
    for (var entity in entities) {
      if (entity is File && entity.path.endsWith('.txt')) {
        try {
          final content = await entity.readAsString();
          final promo = MarketPromotion.fromText(content);
          promotions.add(promo);
        } catch (e) {
          LogService().log('MarketService: Error loading promotion from ${entity.path}: $e');
        }
      }
    }

    // Sort by start date (most recent first)
    promotions.sort((a, b) => b.startDateTime.compareTo(a.startDateTime));

    return promotions;
  }

  /// Get active promotions
  Future<List<MarketPromotion>> getActivePromotions() async {
    final allPromos = await loadPromotions();
    return allPromos.where((p) => p.isCurrentlyActive).toList();
  }

  /// Save promotion
  Future<void> savePromotion(MarketPromotion promotion) async {
    if (_collectionPath == null) return;

    final promosDir = Directory('$_collectionPath/shop/promotions');
    if (!await promosDir.exists()) {
      await promosDir.create(recursive: true);
    }

    final promoFile = File('${promosDir.path}/${promotion.promoId}.txt');
    await promoFile.writeAsString(promotion.exportAsText(), flush: true);

    LogService().log('MarketService: Saved promotion: ${promotion.promoId}');
  }

  // ============================================================================
  // COUPONS
  // ============================================================================

  /// Load all coupons
  Future<List<MarketCoupon>> loadCoupons() async {
    if (_collectionPath == null) return [];

    final couponsDir = Directory('$_collectionPath/coupons');
    if (!await couponsDir.exists()) return [];

    final coupons = <MarketCoupon>[];

    final entities = await couponsDir.list().toList();
    for (var entity in entities) {
      if (entity is File && entity.path.endsWith('.txt')) {
        try {
          final content = await entity.readAsString();
          final coupon = MarketCoupon.fromText(content);
          coupons.add(coupon);
        } catch (e) {
          LogService().log('MarketService: Error loading coupon from ${entity.path}: $e');
        }
      }
    }

    return coupons;
  }

  /// Get valid coupons
  Future<List<MarketCoupon>> getValidCoupons() async {
    final allCoupons = await loadCoupons();
    return allCoupons.where((c) => c.isValid).toList();
  }

  /// Validate coupon code
  Future<MarketCoupon?> validateCoupon(String code, String userNpub) async {
    final coupons = await loadCoupons();
    try {
      final coupon = coupons.firstWhere((c) => c.couponCode.toUpperCase() == code.toUpperCase());
      if (coupon.isValid && coupon.canUserUse(userNpub)) {
        return coupon;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Save coupon
  Future<void> saveCoupon(MarketCoupon coupon) async {
    if (_collectionPath == null) return;

    final couponsDir = Directory('$_collectionPath/coupons');
    if (!await couponsDir.exists()) {
      await couponsDir.create(recursive: true);
    }

    final couponFile = File('${couponsDir.path}/coupon-${coupon.couponCode}.txt');
    await couponFile.writeAsString(coupon.exportAsText(), flush: true);

    LogService().log('MarketService: Saved coupon: ${coupon.couponCode}');
  }

  // ============================================================================
  // UTILITY FUNCTIONS
  // ============================================================================

  /// Generate unique item ID based on content hash
  String generateItemId(String content) {
    final bytes = utf8.encode(content);
    final hash = sha256.convert(bytes);
    return hash.toString().substring(0, 6);
  }

  /// Generate unique order ID based on content hash
  String generateOrderId(String content) {
    final bytes = utf8.encode(content);
    final hash = sha256.convert(bytes);
    final date = DateTime.now();
    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return 'order-${dateStr}_${hash.toString().substring(0, 6)}';
  }

  /// Generate unique cart ID based on buyer and timestamp
  String generateCartId(String buyerCallsign) {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final bytes = utf8.encode('$buyerCallsign-$timestamp');
    final hash = sha256.convert(bytes);
    return 'cart-${buyerCallsign}_${hash.toString().substring(0, 6)}';
  }

  /// Get timestamp in Geogram format (YYYY-MM-DD HH:MM_ss)
  String getTimestamp() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
           '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_'
           '${now.second.toString().padLeft(2, '0')}';
  }
}
