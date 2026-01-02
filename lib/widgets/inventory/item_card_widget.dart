/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

import '../../inventory/models/inventory_item.dart';
import '../../inventory/models/item_type_catalog.dart';
import '../../inventory/models/measurement_units.dart';
import '../../platform/file_image_helper.dart' as file_helper;
import '../../services/i18n_service.dart';

/// Card widget for displaying an inventory item
class ItemCardWidget extends StatelessWidget {
  final InventoryItem item;
  final I18nService i18n;
  final String? mediaBasePath;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool isSelected;

  const ItemCardWidget({
    super.key,
    required this.item,
    required this.i18n,
    this.mediaBasePath,
    this.onTap,
    this.onLongPress,
    this.isSelected = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final langCode = i18n.currentLanguage.split('_').first.toUpperCase();

    // Get item type name
    final itemType = ItemTypeCatalog.getById(item.type);
    final typeName = itemType?.getName(langCode) ?? item.type;

    // Get unit
    final unit = MeasurementUnits.getById(item.unit);
    final unitName = unit?.getName(langCode) ?? item.unit;

    // Status badges
    final badges = <Widget>[];
    if (item.isOutOfStock) {
      badges.add(_buildBadge(context, i18n.t('out_of_stock'), Colors.red));
    } else if (item.isLowStock) {
      badges.add(_buildBadge(context, i18n.t('low_stock'), Colors.orange));
    }
    if (item.hasExpiredBatch) {
      badges.add(_buildBadge(context, i18n.t('expired'), Colors.red));
    } else if (item.hasExpiringSoon) {
      badges.add(_buildBadge(context, i18n.t('expiring_soon'), Colors.orange));
    }

    return Card(
      elevation: isSelected ? 4 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isSelected
            ? BorderSide(color: theme.colorScheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnail
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              child: AspectRatio(
                aspectRatio: 1.5,
                child: _buildThumbnail(context, theme),
              ),
            ),
            // Content - use Expanded to prevent overflow
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Title
                    Text(
                      item.getTitle(langCode),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    // Type
                    Text(
                      typeName,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    // Quantity
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${item.quantity.toStringAsFixed(item.quantity.truncateToDouble() == item.quantity ? 0 : 1)} $unitName',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                              color: item.isOutOfStock
                                  ? Colors.red
                                  : item.isLowStock
                                      ? Colors.orange
                                      : null,
                            ),
                          ),
                        ),
                        if (item.hasCoordinates || item.hasPlace)
                          Icon(
                            Icons.location_on_outlined,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                      ],
                    ),
                    // Badges - only show if there's space
                    if (badges.isNotEmpty) ...[
                      const Spacer(),
                      Wrap(
                        spacing: 4,
                        runSpacing: 2,
                        children: badges,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(BuildContext context, ThemeData theme) {
    if (item.thumbnail != null && mediaBasePath != null) {
      final imagePath = '$mediaBasePath/${item.thumbnail}';
      final imageWidget = file_helper.buildFileImage(
        imagePath,
        fit: BoxFit.cover,
      );
      if (imageWidget != null) {
        return imageWidget;
      }
    }
    return _buildPlaceholder(theme);
  }

  Widget _buildPlaceholder(ThemeData theme) {
    // Get category icon
    final itemType = ItemTypeCatalog.getById(item.type);
    final category = itemType?.category ?? ItemCategory.other;
    final icon = _getCategoryIcon(category);

    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          icon,
          size: 28,
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  IconData _getCategoryIcon(ItemCategory category) {
    switch (category) {
      case ItemCategory.food:
        return Icons.restaurant;
      case ItemCategory.beverages:
        return Icons.local_drink;
      case ItemCategory.household:
        return Icons.home;
      case ItemCategory.electronics:
        return Icons.devices;
      case ItemCategory.tools:
        return Icons.build;
      case ItemCategory.outdoor:
      case ItemCategory.camping:
        return Icons.terrain;
      case ItemCategory.automotive:
        return Icons.directions_car;
      case ItemCategory.office:
        return Icons.work;
      case ItemCategory.medical:
        return Icons.medical_services;
      case ItemCategory.clothing:
        return Icons.checkroom;
      case ItemCategory.sports:
        return Icons.sports;
      case ItemCategory.garden:
        return Icons.grass;
      case ItemCategory.pets:
        return Icons.pets;
      case ItemCategory.crafts:
        return Icons.palette;
      case ItemCategory.music:
        return Icons.music_note;
      case ItemCategory.photography:
        return Icons.camera_alt;
      case ItemCategory.fishing:
        return Icons.phishing;
      case ItemCategory.hunting:
        return Icons.forest;
      case ItemCategory.safety:
        return Icons.security;
      case ItemCategory.cleaning:
        return Icons.cleaning_services;
      case ItemCategory.storage:
        return Icons.storage;
      case ItemCategory.kitchen:
        return Icons.kitchen;
      case ItemCategory.bathroom:
        return Icons.bathtub;
      case ItemCategory.furniture:
        return Icons.chair;
      case ItemCategory.lighting:
        return Icons.light;
      case ItemCategory.other:
        return Icons.inventory_2;
    }
  }

  Widget _buildBadge(BuildContext context, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
    );
  }
}
