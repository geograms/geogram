/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';

import '../models/inventory_folder.dart';
import '../models/inventory_item.dart';
import '../models/inventory_batch.dart';
import '../models/inventory_borrow.dart';
import '../models/inventory_usage.dart';
import '../models/inventory_template.dart';
import '../utils/inventory_folder_utils.dart';
import 'inventory_storage_service.dart';
import '../../services/log_service.dart';

/// Main service for managing inventory operations
class InventoryService {
  static final InventoryService _instance = InventoryService._internal();
  factory InventoryService() => _instance;
  InventoryService._internal();

  InventoryStorageService? _storage;
  String? _currentPath;

  /// Stream controller for inventory changes
  final _changesController = StreamController<InventoryChange>.broadcast();

  /// Stream of inventory changes
  Stream<InventoryChange> get changes => _changesController.stream;

  /// Check if the service is initialized
  bool get isInitialized => _storage != null;

  /// Get the current collection path
  String? get currentPath => _currentPath;

  /// Initialize the service with a collection path
  Future<void> initializeCollection(String path) async {
    _currentPath = path;
    _storage = InventoryStorageService(path);
    await _storage!.initialize();
    LogService().log('InventoryService: Initialized with path $path');
  }

  /// Reset the service (for switching collections)
  void reset() {
    _storage = null;
    _currentPath = null;
  }

  // ============ Folder Operations ============

  /// Get the root folders
  Future<List<InventoryFolder>> getRootFolders() async {
    if (_storage == null) return [];
    return _storage!.listSubfolders([]);
  }

  /// Get subfolders of a folder
  Future<List<InventoryFolder>> getSubfolders(List<String> folderPath) async {
    if (_storage == null) return [];
    return _storage!.listSubfolders(folderPath);
  }

  /// Get folder metadata
  Future<InventoryFolder?> getFolder(List<String> folderPath) async {
    if (_storage == null || folderPath.isEmpty) return null;
    return _storage!.readFolderMetadata(folderPath);
  }

  /// Create a new folder
  Future<InventoryFolder?> createFolder({
    required String name,
    required List<String> parentPath,
    FolderVisibility visibility = FolderVisibility.private,
    Map<String, String>? translations,
  }) async {
    if (_storage == null) return null;

    // Validate depth
    final newDepth = parentPath.length + 1;
    if (!InventoryFolderUtils.isValidFolderDepth(newDepth)) {
      LogService().log('InventoryService: Cannot create folder - max depth exceeded');
      return null;
    }

    // Validate name
    if (!InventoryFolderUtils.isValidFolderName(name)) {
      LogService().log('InventoryService: Cannot create folder - invalid name');
      return null;
    }

    final folder = InventoryFolder(
      id: InventoryFolderUtils.generateFolderId(),
      name: name,
      parentId: parentPath.isNotEmpty ? parentPath.last : null,
      depth: newDepth,
      visibility: visibility,
      translations: translations ?? {},
    );

    final success = await _storage!.createFolder(parentPath, folder);
    if (success) {
      _notifyChange(InventoryChangeType.folderCreated, folderPath: [...parentPath, folder.id]);
      return folder;
    }
    return null;
  }

  /// Update folder metadata
  Future<bool> updateFolder(
    List<String> folderPath,
    InventoryFolder folder,
  ) async {
    if (_storage == null) return false;
    final success = await _storage!.writeFolderMetadata(folderPath, folder);
    if (success) {
      _notifyChange(InventoryChangeType.folderUpdated, folderPath: folderPath);
    }
    return success;
  }

  /// Rename a folder
  Future<bool> renameFolder(List<String> folderPath, String newName) async {
    if (_storage == null) return false;
    if (!InventoryFolderUtils.isValidFolderName(newName)) return false;

    final folder = await _storage!.readFolderMetadata(folderPath);
    if (folder == null) return false;

    folder.name = newName;
    folder.updatedAt = DateTime.now();
    return updateFolder(folderPath, folder);
  }

  /// Delete a folder and all its contents
  Future<bool> deleteFolder(List<String> folderPath) async {
    if (_storage == null || folderPath.isEmpty) return false;
    final success = await _storage!.deleteFolder(folderPath);
    if (success) {
      _notifyChange(InventoryChangeType.folderDeleted, folderPath: folderPath);
    }
    return success;
  }

  // ============ Templates Folder ============

  /// Fixed ID for the templates folder at root
  static const String templatesFolderId = 'templates';

  /// Check if the templates folder exists
  Future<bool> hasTemplatesFolder() async {
    if (_storage == null) return false;
    final folder = await _storage!.readFolderMetadata([templatesFolderId]);
    return folder != null;
  }

  /// Get or create the templates folder at root
  Future<InventoryFolder?> ensureTemplatesFolder() async {
    if (_storage == null) return null;

    // Check if it already exists
    final existing = await _storage!.readFolderMetadata([templatesFolderId]);
    if (existing != null) return existing;

    // Create the templates folder with translations
    final folder = InventoryFolder(
      id: templatesFolderId,
      name: 'templates',
      parentId: null,
      depth: 1,
      visibility: FolderVisibility.private,
      translations: {
        'EN': 'Templates',
        'PT': 'Modelos',
        'ES': 'Plantillas',
        'FR': 'Modèles',
        'DE': 'Vorlagen',
      },
    );

    final success = await _storage!.createFolder([], folder);
    if (success) {
      _notifyChange(InventoryChangeType.folderCreated, folderPath: [templatesFolderId]);
      return folder;
    }
    return null;
  }

  /// Copy an item as a template to the templates folder
  /// [sourcePath] - path to the folder containing the source item
  /// [itemId] - ID of the item to copy
  /// [templateName] - name for the template item
  /// [targetSubfolder] - optional subfolder path within templates folder
  Future<InventoryItem?> copyItemAsTemplate(
    List<String> sourcePath,
    String itemId,
    String templateName, {
    List<String>? targetSubfolder,
  }) async {
    if (_storage == null) return null;

    // Ensure templates folder exists
    final templatesFolder = await ensureTemplatesFolder();
    if (templatesFolder == null) return null;

    // Read the source item
    final sourceItem = await _storage!.readItem(sourcePath, itemId);
    if (sourceItem == null) return null;

    // Create new item with new ID and name
    final templateItem = InventoryItem(
      id: InventoryFolderUtils.generateItemId(),
      title: templateName,
      type: sourceItem.type,
      unit: sourceItem.unit,
      batches: [], // Templates start with no batches
      media: [], // Don't copy media to templates
      specs: Map.from(sourceItem.specs),
      customFields: Map.from(sourceItem.customFields),
      translations: Map.from(sourceItem.translations),
    );

    // Build target path
    final targetPath = [templatesFolderId, ...?targetSubfolder];

    // Save the template item
    final success = await _storage!.writeItem(targetPath, templateItem);
    if (success) {
      _notifyChange(InventoryChangeType.itemCreated, folderPath: targetPath);
      return templateItem;
    }
    return null;
  }

  /// Get all items in the templates folder (including subfolders)
  Future<List<InventoryItem>> getTemplateItems({List<String>? subfolder}) async {
    if (_storage == null) return [];
    final path = [templatesFolderId, ...?subfolder];
    return _storage!.listItems(path);
  }

  /// Get subfolders within the templates folder
  Future<List<InventoryFolder>> getTemplateSubfolders({List<String>? subfolder}) async {
    if (_storage == null) return [];
    final path = [templatesFolderId, ...?subfolder];
    return _storage!.listSubfolders(path);
  }

  // ============ Item Operations ============

  /// Get all items in a folder
  Future<List<InventoryItem>> getItems(List<String> folderPath) async {
    if (_storage == null) return [];
    return _storage!.listItems(folderPath);
  }

  /// Get a single item
  Future<InventoryItem?> getItem(List<String> folderPath, String itemId) async {
    if (_storage == null) return null;
    return _storage!.readItem(folderPath, itemId);
  }

  /// Create a new item
  /// The item is a generic definition; batches contain the actual quantities
  Future<InventoryItem?> createItem({
    required List<String> folderPath,
    required String title,
    required String type,
    String unit = 'units',
    List<InventoryBatch>? batches,
    List<String>? media,
    Map<String, dynamic>? specs,
    Map<String, dynamic>? customFields,
    Map<String, String>? translations,
    String? location,
    String? locationName,
    String? placePath,
  }) async {
    if (_storage == null) return null;

    final item = InventoryItem(
      id: InventoryFolderUtils.generateItemId(),
      title: title,
      type: type,
      unit: unit,
      batches: batches ?? [],
      media: media ?? [],
      specs: specs ?? {},
      customFields: customFields ?? {},
      translations: translations ?? {},
      location: location ?? '',
      locationName: locationName,
      metadata: placePath != null ? {'place_path': placePath} : {},
    );

    final success = await _storage!.writeItem(folderPath, item);
    if (success) {
      _notifyChange(InventoryChangeType.itemCreated, folderPath: folderPath, itemId: item.id);
      return item;
    }
    return null;
  }

  /// Create an item from a template
  Future<InventoryItem?> createItemFromTemplate({
    required List<String> folderPath,
    required String templateId,
    Map<String, dynamic>? overrides,
  }) async {
    if (_storage == null) return null;

    final template = await _storage!.readTemplate(templateId);
    if (template == null) return null;

    final defaults = template.itemDefaults;
    final item = await createItem(
      folderPath: folderPath,
      title: overrides?['title'] ?? defaults['title'] ?? template.name,
      type: overrides?['type'] ?? defaults['type'] ?? 'other',
      unit: overrides?['unit'] ?? defaults['unit'] ?? 'units',
      specs: overrides?['specs'] ?? defaults['specs'],
      customFields: overrides?['custom_fields'] ?? defaults['custom_fields'],
    );

    if (item != null) {
      // Increment template use count
      template.incrementUseCount();
      await _storage!.writeTemplate(template);
    }

    return item;
  }

  /// Update an item
  Future<bool> updateItem(List<String> folderPath, InventoryItem item) async {
    if (_storage == null) return false;
    item.updatedAt = DateTime.now();
    final success = await _storage!.writeItem(folderPath, item);
    if (success) {
      _notifyChange(InventoryChangeType.itemUpdated, folderPath: folderPath, itemId: item.id);
    }
    return success;
  }

  /// Delete an item
  Future<bool> deleteItem(List<String> folderPath, String itemId) async {
    if (_storage == null) return false;
    final success = await _storage!.deleteItem(folderPath, itemId);
    if (success) {
      _notifyChange(InventoryChangeType.itemDeleted, folderPath: folderPath, itemId: itemId);
    }
    return success;
  }

  /// Move an item to a different folder
  Future<bool> moveItem(
    List<String> sourcePath,
    String itemId,
    List<String> targetPath,
  ) async {
    if (_storage == null) return false;

    final item = await _storage!.readItem(sourcePath, itemId);
    if (item == null) return false;

    // Write to new location
    final writeSuccess = await _storage!.writeItem(targetPath, item);
    if (!writeSuccess) return false;

    // Delete from old location
    final deleteSuccess = await _storage!.deleteItem(sourcePath, itemId);
    if (deleteSuccess) {
      _notifyChange(InventoryChangeType.itemMoved, folderPath: targetPath, itemId: itemId);
    }
    return deleteSuccess;
  }

  // ============ Batch Operations ============

  /// Add a batch to an item
  Future<bool> addBatch(
    List<String> folderPath,
    String itemId, {
    required double quantity,
    DateTime? datePurchased,
    DateTime? dateExpired,
    double? cost,
    String? currency,
    String? supplier,
    String? notes,
  }) async {
    if (_storage == null) return false;

    final item = await _storage!.readItem(folderPath, itemId);
    if (item == null) return false;

    final batch = InventoryBatch(
      id: InventoryFolderUtils.generateBatchId(),
      quantity: quantity,
      datePurchased: datePurchased,
      dateExpired: dateExpired,
      cost: cost,
      currency: currency,
      supplier: supplier,
      notes: notes,
    );

    item.batches.add(batch);
    return updateItem(folderPath, item);
  }

  /// Update a batch
  Future<bool> updateBatch(
    List<String> folderPath,
    String itemId,
    InventoryBatch batch,
  ) async {
    if (_storage == null) return false;

    final item = await _storage!.readItem(folderPath, itemId);
    if (item == null) return false;

    final index = item.batches.indexWhere((b) => b.id == batch.id);
    if (index < 0) return false;

    item.batches[index] = batch;
    return updateItem(folderPath, item);
  }

  /// Remove a batch
  Future<bool> removeBatch(
    List<String> folderPath,
    String itemId,
    String batchId,
  ) async {
    if (_storage == null) return false;

    final item = await _storage!.readItem(folderPath, itemId);
    if (item == null) return false;

    item.batches.removeWhere((b) => b.id == batchId);
    return updateItem(folderPath, item);
  }

  // ============ Usage Operations ============

  /// Consume quantity from an item (deducts from batches using FIFO)
  Future<bool> consumeItem(
    List<String> folderPath,
    String itemId, {
    required double quantity,
    String? batchId,
    String? reason,
    String? notes,
  }) async {
    if (_storage == null) return false;

    final item = await _storage!.readItem(folderPath, itemId);
    if (item == null) return false;

    // Validate quantity
    if (quantity <= 0 || quantity > item.quantity) return false;

    // Must have batches to consume from
    if (item.batches.isEmpty) return false;

    double remaining = quantity;
    if (batchId != null) {
      // Consume from specific batch
      final batch = item.batches.firstWhere(
        (b) => b.id == batchId,
        orElse: () => throw Exception('Batch not found'),
      );
      if (batch.quantity < quantity) return false;
      batch.quantity -= quantity;
    } else {
      // FIFO: consume from oldest batches first (by expiry or purchase date)
      final sortedBatches = List<InventoryBatch>.from(item.batches)
        ..sort((a, b) {
          final dateA = a.dateExpired ?? a.datePurchased ?? a.createdAt;
          final dateB = b.dateExpired ?? b.datePurchased ?? b.createdAt;
          return dateA.compareTo(dateB);
        });

      for (final batch in sortedBatches) {
        if (remaining <= 0) break;
        final consume = remaining > batch.quantity ? batch.quantity : remaining;
        batch.quantity -= consume;
        remaining -= consume;
      }
    }

    // Record usage event
    final usage = InventoryUsage(
      id: InventoryFolderUtils.generateUsageId(),
      itemId: itemId,
      type: UsageType.consume,
      quantity: quantity,
      unit: item.unit,
      batchId: batchId,
      reason: reason,
      notes: notes,
    );
    await _storage!.appendUsage(folderPath, usage);

    return updateItem(folderPath, item);
  }

  /// Refill/add quantity - adds to existing batch or creates a new one
  Future<bool> refillItem(
    List<String> folderPath,
    String itemId, {
    required double quantity,
    String? batchId,
    String? reason,
    String? notes,
  }) async {
    if (_storage == null) return false;

    final item = await _storage!.readItem(folderPath, itemId);
    if (item == null) return false;

    if (quantity <= 0) return false;

    if (batchId != null) {
      // Add to existing batch
      final batchIndex = item.batches.indexWhere((b) => b.id == batchId);
      if (batchIndex < 0) return false;

      final batch = item.batches[batchIndex];
      batch.quantity += quantity;
      batch.initialQuantity += quantity;
    } else {
      // Create a new batch for the refill
      final newBatch = InventoryBatch(
        id: InventoryFolderUtils.generateBatchId(),
        quantity: quantity,
        datePurchased: DateTime.now(),
        notes: reason ?? notes,
      );
      item.batches.add(newBatch);
    }

    // Record usage event
    final usage = InventoryUsage(
      id: InventoryFolderUtils.generateUsageId(),
      itemId: itemId,
      type: UsageType.refill,
      quantity: quantity,
      unit: item.unit,
      batchId: batchId,
      reason: reason,
      notes: notes,
    );
    await _storage!.appendUsage(folderPath, usage);

    return updateItem(folderPath, item);
  }

  /// Adjust quantity of a specific batch (can be positive or negative)
  Future<bool> adjustItem(
    List<String> folderPath,
    String itemId, {
    required double adjustment,
    String? batchId,
    String? reason,
    String? notes,
  }) async {
    if (_storage == null) return false;

    final item = await _storage!.readItem(folderPath, itemId);
    if (item == null) return false;

    if (item.batches.isEmpty) return false;

    // Find target batch
    InventoryBatch targetBatch;
    if (batchId != null) {
      final idx = item.batches.indexWhere((b) => b.id == batchId);
      if (idx < 0) return false;
      targetBatch = item.batches[idx];
    } else {
      // Use the first batch if no specific batch specified
      targetBatch = item.batches.first;
    }

    final newBatchQuantity = targetBatch.quantity + adjustment;
    if (newBatchQuantity < 0) return false;

    targetBatch.quantity = newBatchQuantity;
    if (adjustment > 0) {
      targetBatch.initialQuantity += adjustment;
    }

    // Record usage event
    final usage = InventoryUsage(
      id: InventoryFolderUtils.generateUsageId(),
      itemId: itemId,
      type: UsageType.adjustment,
      quantity: adjustment,
      unit: item.unit,
      batchId: batchId,
      reason: reason,
      notes: notes,
    );
    await _storage!.appendUsage(folderPath, usage);

    return updateItem(folderPath, item);
  }

  /// Get usage history for an item
  Future<List<InventoryUsage>> getUsageHistory(
    List<String> folderPath, {
    String? itemId,
  }) async {
    if (_storage == null) return [];
    final usage = await _storage!.readUsage(folderPath);
    if (itemId == null) return usage;
    return usage.where((u) => u.itemId == itemId).toList();
  }

  /// Update a usage entry (e.g., to correct the timestamp)
  Future<bool> updateUsage(
    List<String> folderPath,
    InventoryUsage updatedUsage,
  ) async {
    if (_storage == null) return false;

    final allUsage = await _storage!.readUsage(folderPath);
    final index = allUsage.indexWhere((u) => u.id == updatedUsage.id);
    if (index == -1) return false;

    allUsage[index] = updatedUsage;
    final success = await _storage!.writeUsage(folderPath, allUsage);
    if (success) {
      _notifyChange(InventoryChangeType.itemUpdated, folderPath: folderPath);
    }
    return success;
  }

  /// Delete a usage entry
  Future<bool> deleteUsage(
    List<String> folderPath,
    String usageId,
  ) async {
    if (_storage == null) return false;

    final allUsage = await _storage!.readUsage(folderPath);
    final index = allUsage.indexWhere((u) => u.id == usageId);
    if (index == -1) return false;

    allUsage.removeAt(index);
    final success = await _storage!.writeUsage(folderPath, allUsage);
    if (success) {
      _notifyChange(InventoryChangeType.itemUpdated, folderPath: folderPath);
    }
    return success;
  }

  // ============ Borrow Operations ============

  /// Lend an item to someone (consumes from batches using FIFO)
  Future<InventoryBorrow?> lendItem(
    List<String> folderPath,
    String itemId, {
    required double quantity,
    required BorrowerType borrowerType,
    String? borrowerCallsign,
    String? borrowerText,
    DateTime? expectedReturnAt,
    String? notes,
  }) async {
    if (_storage == null) return null;

    final item = await _storage!.readItem(folderPath, itemId);
    if (item == null) return null;

    // Validate quantity
    if (quantity <= 0 || quantity > item.quantity) return null;
    if (item.batches.isEmpty) return null;

    // Consume from batches using FIFO
    double remaining = quantity;
    final sortedBatches = List<InventoryBatch>.from(item.batches)
      ..sort((a, b) {
        final dateA = a.dateExpired ?? a.datePurchased ?? a.createdAt;
        final dateB = b.dateExpired ?? b.datePurchased ?? b.createdAt;
        return dateA.compareTo(dateB);
      });

    for (final batch in sortedBatches) {
      if (remaining <= 0) break;
      final consume = remaining > batch.quantity ? batch.quantity : remaining;
      batch.quantity -= consume;
      remaining -= consume;
    }

    await _storage!.writeItem(folderPath, item);

    // Create borrow record
    final borrow = InventoryBorrow(
      id: InventoryFolderUtils.generateBorrowId(),
      itemId: itemId,
      quantity: quantity,
      unit: item.unit,
      borrowerType: borrowerType,
      borrowerCallsign: borrowerCallsign,
      borrowerText: borrowerText,
      borrowedAt: DateTime.now(),
      expectedReturnAt: expectedReturnAt,
      notes: notes,
    );

    final borrows = await _storage!.readBorrows(folderPath);
    borrows.add(borrow);
    await _storage!.writeBorrows(folderPath, borrows);

    _notifyChange(InventoryChangeType.itemBorrowed, folderPath: folderPath, itemId: itemId);
    return borrow;
  }

  /// Return a borrowed item (adds a new batch for the returned quantity)
  Future<bool> returnItem(
    List<String> folderPath,
    String borrowId, {
    double? returnedQuantity,
    String? notes,
  }) async {
    if (_storage == null) return false;

    final borrows = await _storage!.readBorrows(folderPath);
    final borrowIndex = borrows.indexWhere((b) => b.id == borrowId);
    if (borrowIndex < 0) return false;

    final borrow = borrows[borrowIndex];
    if (!borrow.isActive) return false;

    final actualReturned = returnedQuantity ?? borrow.quantity;

    // Get item and add back quantity as a new batch
    final item = await _storage!.readItem(folderPath, borrow.itemId);
    if (item == null) return false;

    // Add returned quantity as a new batch
    final returnBatch = InventoryBatch(
      id: InventoryFolderUtils.generateBatchId(),
      quantity: actualReturned,
      datePurchased: DateTime.now(),
      notes: 'Returned from borrow: ${borrow.id}',
    );
    item.batches.add(returnBatch);
    await _storage!.writeItem(folderPath, item);

    // Update borrow record
    borrow.returnedAt = DateTime.now();
    borrow.returnedQuantity = actualReturned;
    borrow.updatedAt = DateTime.now();
    borrows[borrowIndex] = borrow;
    await _storage!.writeBorrows(folderPath, borrows);

    _notifyChange(InventoryChangeType.itemReturned, folderPath: folderPath, itemId: borrow.itemId);
    return true;
  }

  /// Get active borrows for a folder
  Future<List<InventoryBorrow>> getActiveBorrows(List<String> folderPath) async {
    if (_storage == null) return [];
    final borrows = await _storage!.readBorrows(folderPath);
    return borrows.where((b) => b.isActive).toList();
  }

  /// Get borrow history for an item
  Future<List<InventoryBorrow>> getBorrowHistory(
    List<String> folderPath, {
    String? itemId,
  }) async {
    if (_storage == null) return [];
    final borrows = await _storage!.readBorrows(folderPath);
    if (itemId == null) return borrows;
    return borrows.where((b) => b.itemId == itemId).toList();
  }

  // ============ Template Operations ============

  /// Get all templates
  Future<List<InventoryTemplate>> getTemplates() async {
    if (_storage == null) return [];
    return _storage!.listTemplates();
  }

  /// Get a template
  Future<InventoryTemplate?> getTemplate(String templateId) async {
    if (_storage == null) return null;
    return _storage!.readTemplate(templateId);
  }

  /// Create a template
  Future<InventoryTemplate?> createTemplate({
    required String name,
    String? description,
    required Map<String, dynamic> itemDefaults,
    Map<String, String>? translations,
  }) async {
    if (_storage == null) return null;

    final template = InventoryTemplate(
      id: InventoryFolderUtils.generateTemplateId(),
      name: name,
      description: description,
      itemDefaults: itemDefaults,
      translations: translations ?? {},
    );

    final success = await _storage!.writeTemplate(template);
    if (success) {
      _notifyChange(InventoryChangeType.templateCreated);
      return template;
    }
    return null;
  }

  /// Create a template from an existing item
  Future<InventoryTemplate?> createTemplateFromItem(
    List<String> folderPath,
    String itemId, {
    required String templateName,
    String? description,
  }) async {
    if (_storage == null) return null;

    final item = await _storage!.readItem(folderPath, itemId);
    if (item == null) return null;

    return createTemplate(
      name: templateName,
      description: description,
      itemDefaults: {
        'title': item.title,
        'type': item.type,
        'unit': item.unit,
        'specs': item.specs,
        'custom_fields': item.customFields,
      },
    );
  }

  /// Update a template
  Future<bool> updateTemplate(InventoryTemplate template) async {
    if (_storage == null) return false;
    template.updatedAt = DateTime.now();
    final success = await _storage!.writeTemplate(template);
    if (success) {
      _notifyChange(InventoryChangeType.templateUpdated);
    }
    return success;
  }

  /// Delete a template
  Future<bool> deleteTemplate(String templateId) async {
    if (_storage == null) return false;
    final success = await _storage!.deleteTemplate(templateId);
    if (success) {
      _notifyChange(InventoryChangeType.templateDeleted);
    }
    return success;
  }

  // ============ Media Operations ============

  /// Add media to a folder
  Future<String?> addMedia(
    List<String> folderPath,
    String sourcePath,
    String filename,
  ) async {
    if (_storage == null) return null;
    return _storage!.copyMediaFile(folderPath, sourcePath, filename);
  }

  /// Remove media from a folder
  Future<bool> removeMedia(List<String> folderPath, String filename) async {
    if (_storage == null) return false;
    return _storage!.deleteMediaFile(folderPath, filename);
  }

  /// Get full path to media file
  String? getMediaPath(List<String> folderPath, String filename) {
    if (_storage == null) return null;
    return _storage!.getMediaFilePath(folderPath, filename);
  }

  /// List media in a folder
  Future<List<String>> getMedia(List<String> folderPath) async {
    if (_storage == null) return [];
    return _storage!.listMediaFiles(folderPath);
  }

  // ============ Search Operations ============

  /// Search items in a folder and subfolders
  Future<List<_SearchResult>> searchItems(
    String query, {
    List<String>? startPath,
    bool recursive = true,
  }) async {
    if (_storage == null) return [];

    final results = <_SearchResult>[];
    final searchPath = startPath ?? [];
    final q = query.toLowerCase();

    Future<void> search(List<String> folderPath) async {
      // Search items in current folder
      final items = await _storage!.listItems(folderPath);
      for (final item in items) {
        if (item.title.toLowerCase().contains(q) ||
            item.type.toLowerCase().contains(q)) {
          results.add(_SearchResult(folderPath: folderPath, item: item));
        }
      }

      // Search subfolders if recursive
      if (recursive) {
        final subfolders = await _storage!.listSubfolders(folderPath);
        for (final subfolder in subfolders) {
          await search([...folderPath, subfolder.id]);
        }
      }
    }

    await search(searchPath);
    return results;
  }

  // ============ Helper Methods ============

  void _notifyChange(
    InventoryChangeType type, {
    List<String>? folderPath,
    String? itemId,
  }) {
    _changesController.add(InventoryChange(
      type: type,
      folderPath: folderPath,
      itemId: itemId,
    ));
  }

  void dispose() {
    _changesController.close();
  }
}

/// Types of inventory changes
enum InventoryChangeType {
  folderCreated,
  folderUpdated,
  folderDeleted,
  itemCreated,
  itemUpdated,
  itemDeleted,
  itemMoved,
  itemBorrowed,
  itemReturned,
  templateCreated,
  templateUpdated,
  templateDeleted,
}

/// Represents an inventory change event
class InventoryChange {
  final InventoryChangeType type;
  final List<String>? folderPath;
  final String? itemId;
  final DateTime timestamp;

  InventoryChange({
    required this.type,
    this.folderPath,
    this.itemId,
  }) : timestamp = DateTime.now();
}

/// Search result
class _SearchResult {
  final List<String> folderPath;
  final InventoryItem item;

  _SearchResult({required this.folderPath, required this.item});
}
