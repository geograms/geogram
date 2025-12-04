/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../models/collection.dart';
import '../services/collection_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';

/// Full-page UI for creating a new collection
/// Features a two-column layout: type selector on left, details panel on right
class CreateCollectionPage extends StatefulWidget {
  const CreateCollectionPage({super.key});

  @override
  State<CreateCollectionPage> createState() => _CreateCollectionPageState();
}

class _CreateCollectionPageState extends State<CreateCollectionPage> {
  final I18nService _i18n = I18nService();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();

  String _selectedType = 'places';
  String _visibility = 'public';
  bool _useAutoFolder = true;
  String? _selectedFolderPath;
  bool _isCreating = false;
  Set<String> _existingTypes = {};

  // Collection types with their icons (ordered by relevance)
  static const List<_CollectionTypeInfo> _collectionTypes = [
    _CollectionTypeInfo('places', Icons.place),
    _CollectionTypeInfo('blog', Icons.article),
    _CollectionTypeInfo('chat', Icons.chat),
    _CollectionTypeInfo('events', Icons.event),
    _CollectionTypeInfo('forum', Icons.forum),
    _CollectionTypeInfo('alerts', Icons.notifications_active),
    _CollectionTypeInfo('news', Icons.newspaper),
    _CollectionTypeInfo('www', Icons.language),
    _CollectionTypeInfo('files', Icons.folder),
    _CollectionTypeInfo('postcards', Icons.mail),
    _CollectionTypeInfo('contacts', Icons.contacts),
    _CollectionTypeInfo('market', Icons.storefront),
    _CollectionTypeInfo('groups', Icons.groups),
  ];

  // Breakpoint for switching to portrait/stacked layout
  static const double _portraitBreakpoint = 600;

  // Single-instance types (all except 'files')
  static const Set<String> _singleInstanceTypes = {
    'forum', 'chat', 'blog', 'events', 'news', 'www',
    'postcards', 'contacts', 'places', 'market', 'alerts', 'groups'
  };

  @override
  void initState() {
    super.initState();
    _checkExistingTypes();
  }

  Future<void> _checkExistingTypes() async {
    try {
      final collectionsService = CollectionService();
      final collectionsDir = Directory('${collectionsService.getDefaultCollectionsPath()}');

      if (await collectionsDir.exists()) {
        final folders = await collectionsDir.list().toList();
        final existingFolderNames = folders
            .where((e) => e is Directory)
            .map((e) => e.path.split('/').last)
            .toSet();

        setState(() {
          _existingTypes = _singleInstanceTypes.intersection(existingFolderNames);
          // Select the first available type that isn't already created
          _selectedType = _collectionTypes
              .map((t) => t.type)
              .firstWhere(
                (type) => !_existingTypes.contains(type),
                orElse: () => 'files', // Fallback to files which allows multiple
              );
        });
      }
    } catch (e) {
      LogService().log('Error checking existing types: $e');
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  bool get _canCreate {
    if (_isCreating) return false;
    if (_selectedType == 'files') {
      if (_titleController.text.trim().isEmpty) return false;
      if (!_useAutoFolder && _selectedFolderPath == null) return false;
    } else {
      if (_existingTypes.contains(_selectedType)) return false;
    }
    return true;
  }

  Future<void> _pickFolder() async {
    try {
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select root folder for collection',
      );

      if (result != null) {
        setState(() {
          _selectedFolderPath = result;
        });
      }
    } catch (e) {
      LogService().log('Error picking folder: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error selecting folder: $e')),
        );
      }
    }
  }

  Future<void> _create() async {
    if (!_canCreate) return;

    setState(() => _isCreating = true);

    try {
      final title = _selectedType == 'files'
          ? _titleController.text.trim()
          : _i18n.t('collection_type_$_selectedType');

      final collection = await CollectionService().createCollection(
        title: title,
        description: _descriptionController.text.trim(),
        type: _selectedType,
        customRootPath: _selectedType == 'files'
            ? (_useAutoFolder ? null : _selectedFolderPath)
            : null,
      );

      // Update visibility if not public
      if (_selectedType == 'files' && _visibility != 'public') {
        collection.visibility = _visibility;
        await CollectionService().updateCollection(collection);
      }

      LogService().log('Created collection: ${collection.title}');

      if (mounted) {
        Navigator.pop(context, collection);
      }
    } catch (e, stackTrace) {
      LogService().log('ERROR creating collection: $e');
      LogService().log('Stack trace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating collection: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isCreating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('create_collection_title')),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _canCreate ? _create : null,
        backgroundColor: _canCreate
            ? theme.colorScheme.primary
            : theme.colorScheme.surfaceContainerHighest,
        foregroundColor: _canCreate
            ? theme.colorScheme.onPrimary
            : theme.colorScheme.onSurface.withOpacity(0.38),
        icon: _isCreating
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _canCreate
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurface.withOpacity(0.38),
                ),
              )
            : const Icon(Icons.add),
        label: Text(_i18n.t('create')),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isPortrait = constraints.maxWidth < _portraitBreakpoint;

          if (isPortrait) {
            // Portrait/narrow layout - stacked vertically
            return Column(
              children: [
                // Type selector as horizontal scrollable list
                SizedBox(
                  height: 56,
                  child: _buildTypeSelector(theme, isPortrait: true),
                ),
                const Divider(height: 1),
                // Details panel takes remaining space
                Expanded(
                  child: _buildDetailsPanel(theme),
                ),
              ],
            );
          }

          // Landscape/wide layout - side by side
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left column - Type selector
              SizedBox(
                width: 280,
                child: _buildTypeSelector(theme, isPortrait: false),
              ),
              const VerticalDivider(width: 1),
              // Right column - Details panel
              Expanded(
                child: _buildDetailsPanel(theme),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTypeSelector(ThemeData theme, {required bool isPortrait}) {
    if (isPortrait) {
      // Portrait mode - horizontal scrollable list
      return Container(
        color: theme.colorScheme.surfaceContainerLow,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          itemCount: _collectionTypes.length,
          itemBuilder: (context, index) {
            final typeInfo = _collectionTypes[index];
            final isSelected = typeInfo.type == _selectedType;
            final isDisabled = _existingTypes.contains(typeInfo.type);

            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                selected: isSelected,
                onSelected: isDisabled
                    ? null
                    : (_) {
                        setState(() {
                          _selectedType = typeInfo.type;
                        });
                      },
                avatar: Icon(
                  typeInfo.icon,
                  size: 18,
                  color: isDisabled
                      ? theme.colorScheme.onSurface.withOpacity(0.38)
                      : isSelected
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurfaceVariant,
                ),
                label: Text(
                  _i18n.t('collection_type_${typeInfo.type}'),
                  style: TextStyle(
                    color: isDisabled
                        ? theme.colorScheme.onSurface.withOpacity(0.38)
                        : null,
                  ),
                ),
                showCheckmark: false,
              ),
            );
          },
        ),
      );
    }

    // Landscape mode - vertical list
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        itemCount: _collectionTypes.length,
        itemBuilder: (context, index) {
          final typeInfo = _collectionTypes[index];
          final isSelected = typeInfo.type == _selectedType;
          final isDisabled = _existingTypes.contains(typeInfo.type);
          final isMultipleAllowed = typeInfo.type == 'files';

          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Material(
              color: isSelected
                  ? theme.colorScheme.primaryContainer
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                onTap: isDisabled
                    ? null
                    : () {
                        setState(() {
                          _selectedType = typeInfo.type;
                        });
                      },
                borderRadius: BorderRadius.circular(12),
                child: Opacity(
                  opacity: isDisabled ? 0.5 : 1.0,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          typeInfo.icon,
                          size: 24,
                          color: isSelected
                              ? theme.colorScheme.onPrimaryContainer
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _i18n.t('collection_type_${typeInfo.type}'),
                            style: TextStyle(
                              fontWeight: isSelected
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              color: isSelected
                                  ? theme.colorScheme.onPrimaryContainer
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                        if (isDisabled)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _i18n.t('exists'),
                              style: TextStyle(
                                fontSize: 10,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        else if (isMultipleAllowed)
                          Icon(
                            Icons.add_circle_outline,
                            size: 16,
                            color: theme.colorScheme.primary,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDetailsPanel(ThemeData theme) {
    final typeInfo = _collectionTypes.firstWhere(
      (t) => t.type == _selectedType,
      orElse: () => _collectionTypes.first,
    );
    final isDisabled = _existingTypes.contains(_selectedType);

    return Align(
      alignment: Alignment.topLeft,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          // Header with icon and title
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  typeInfo.icon,
                  size: 32,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _i18n.t('collection_type_$_selectedType'),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_selectedType == 'files')
                      Chip(
                        label: Text(_i18n.t('multiple_allowed')),
                        backgroundColor: theme.colorScheme.primaryContainer,
                        labelStyle: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      )
                    else if (isDisabled)
                      Chip(
                        label: Text(_i18n.t('already_exists')),
                        backgroundColor: theme.colorScheme.errorContainer,
                        labelStyle: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onErrorContainer,
                        ),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Description
          Text(
            _getTypeDescription(_selectedType),
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),

          // Features list
          _buildFeaturesList(theme),

          // Settings section (only for 'files' type)
          if (_selectedType == 'files' && !isDisabled) ...[
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 24),
            Text(
              _i18n.t('settings'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            _buildSettingsForm(theme),
          ],

          // Disabled message for existing single-instance types
          if (isDisabled) ...[
            const SizedBox(height: 32),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withOpacity(0.3),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: theme.colorScheme.error.withOpacity(0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _i18n.t('collection_type_exists_message'),
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      ),
    );
  }

  Widget _buildFeaturesList(ThemeData theme) {
    final features = _getTypeFeatures(_selectedType);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _i18n.t('features'),
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 8),
        ...features.map((feature) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.check_circle,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  feature,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        )),
      ],
    );
  }

  Widget _buildSettingsForm(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title field
        TextField(
          controller: _titleController,
          decoration: InputDecoration(
            labelText: _i18n.t('collection_title'),
            hintText: _i18n.t('collection_title_hint'),
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.title),
          ),
          autofocus: true,
          enabled: !_isCreating,
          textInputAction: TextInputAction.next,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),

        // Description field
        TextField(
          controller: _descriptionController,
          decoration: InputDecoration(
            labelText: _i18n.t('collection_description'),
            hintText: _i18n.t('collection_description_hint'),
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.description),
          ),
          maxLines: 3,
          enabled: !_isCreating,
        ),
        const SizedBox(height: 16),

        // Visibility dropdown
        DropdownButtonFormField<String>(
          value: _visibility,
          decoration: InputDecoration(
            labelText: _i18n.t('visibility'),
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.visibility),
          ),
          items: [
            DropdownMenuItem(
              value: 'public',
              child: Text(_i18n.t('visibility_public')),
            ),
            DropdownMenuItem(
              value: 'private',
              child: Text(_i18n.t('visibility_private')),
            ),
            DropdownMenuItem(
              value: 'restricted',
              child: Text(_i18n.t('visibility_restricted')),
            ),
          ],
          onChanged: _isCreating
              ? null
              : (value) {
                  if (value != null) {
                    setState(() {
                      _visibility = value;
                    });
                  }
                },
        ),
        const SizedBox(height: 24),

        // Folder selection
        Text(
          _i18n.t('storage_location'),
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          title: Text(_i18n.t('use_default_folder')),
          subtitle: Text(
            _useAutoFolder
                ? '~/Documents/geogram/devices/${CollectionService().currentCallsign ?? "..."}'
                : _i18n.t('choose_custom_location'),
            style: theme.textTheme.bodySmall,
          ),
          value: _useAutoFolder,
          enabled: !_isCreating,
          onChanged: (value) {
            setState(() {
              _useAutoFolder = value ?? true;
              if (_useAutoFolder) {
                _selectedFolderPath = null;
              }
            });
          },
          contentPadding: EdgeInsets.zero,
        ),

        // Custom folder picker
        if (!_useAutoFolder) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _isCreating ? null : _pickFolder,
            icon: const Icon(Icons.folder_open),
            label: Text(_i18n.t('choose_folder')),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
          if (_selectedFolderPath != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.folder,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _selectedFolderPath!,
                      style: theme.textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ],
    );
  }

  String _getTypeDescription(String type) {
    // Try to get from i18n, fallback to default descriptions
    final key = 'collection_type_desc_$type';
    final translated = _i18n.t(key);
    if (translated != key) return translated;

    // Fallback descriptions
    switch (type) {
      case 'files':
        return 'Store and organize files in custom folders. Create multiple collections for different purposes like documents, photos, or projects.';
      case 'forum':
        return 'Discussion forum for threaded conversations and community discussions. Topics are organized by categories with support for replies and moderation.';
      case 'chat':
        return 'Real-time messaging with support for multiple channels. Perfect for team communication or group discussions.';
      case 'blog':
        return 'Publish articles and posts for sharing your thoughts, tutorials, or updates. Supports rich content with images and formatting.';
      case 'events':
        return 'Create and manage events with dates, times, locations, and attendee registration. Great for organizing meetups or activities.';
      case 'news':
        return 'Share news and announcements with your network. Keep your community informed about updates and important information.';
      case 'www':
        return 'Host a personal website with full HTML, CSS, and JavaScript support. Accessible via your relay URL.';
      case 'postcards':
        return 'Send and receive digital postcards with images and personal messages. A fun way to share memories and greetings.';
      case 'contacts':
        return 'Store contact information for people and organizations. Keep your network organized and accessible.';
      case 'places':
        return 'Save and share locations with maps, coordinates, and descriptions. Document interesting places or share recommendations.';
      case 'market':
        return 'List items for sale, trade, or giveaway. A simple marketplace for your community.';
      case 'alerts':
        return 'Receive and manage alerts and notifications. Stay informed about important updates and events in your network.';
      case 'groups':
        return 'Organize people into groups for easier management and communication. Create teams or interest groups.';
      case 'relay':
        return 'Relay configuration for network communication settings. Manage how your node connects to the network.';
      default:
        return '';
    }
  }

  List<String> _getTypeFeatures(String type) {
    // Try to get from i18n first
    final key = 'collection_type_features_$type';
    final translated = _i18n.t(key);
    if (translated != key) {
      return translated.split('|');
    }

    // Fallback features
    switch (type) {
      case 'files':
        return [
          'Organize files by folders',
          'Share with specific users',
          'Set visibility permissions',
          'Multiple collections allowed',
        ];
      case 'forum':
        return [
          'Threaded discussions',
          'Categories and topics',
          'User moderation',
          'Pinned topics',
        ];
      case 'chat':
        return [
          'Multiple channels',
          'Text, image, and file sharing',
          'Message history',
          'Participant management',
        ];
      case 'blog':
        return [
          'Rich text editor',
          'Image embedding',
          'Draft saving',
          'Post scheduling',
        ];
      case 'events':
        return [
          'Date/time scheduling',
          'Location mapping',
          'Registration',
          'Reminders',
        ];
      case 'news':
        return [
          'Chronological feed',
          'Categories',
          'Featured posts',
          'Notifications',
        ];
      case 'www':
        return [
          'Full web hosting',
          'Custom HTML/CSS/JS',
          'Accessible at relay-url/callsign',
        ];
      case 'postcards':
        return [
          'Image attachments',
          'Personal messages',
          'Send/receive tracking',
        ];
      case 'contacts':
        return [
          'Contact details',
          'Organization info',
          'Search',
          'Export',
        ];
      case 'places':
        return [
          'Map integration',
          'Coordinates',
          'Descriptions',
          'Photos',
        ];
      case 'market':
        return [
          'Item listings',
          'Pricing',
          'Categories',
          'Contact seller',
        ];
      case 'alerts':
        return [
          'Real-time notifications',
          'Priority levels',
          'Alert history',
          'Custom filters',
        ];
      case 'groups':
        return [
          'Member management',
          'Group roles',
          'Bulk actions',
        ];
      case 'relay':
        return [
          'Connection settings',
          'Peer management',
          'Bandwidth controls',
        ];
      default:
        return [];
    }
  }
}

/// Helper class for collection type information
class _CollectionTypeInfo {
  final String type;
  final IconData icon;

  const _CollectionTypeInfo(this.type, this.icon);
}
