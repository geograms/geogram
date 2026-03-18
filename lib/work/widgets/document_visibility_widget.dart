/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/i18n_service.dart';
import '../../tracker/models/tracker_visibility.dart';

/// Reusable widget for setting NDF document visibility.
/// Works with TrackerVisibility from the tracker module.
class DocumentVisibilityWidget extends StatefulWidget {
  final TrackerVisibility visibility;
  final ValueChanged<TrackerVisibility> onChanged;
  final String? shareUrl;

  const DocumentVisibilityWidget({
    super.key,
    required this.visibility,
    required this.onChanged,
    this.shareUrl,
  });

  @override
  State<DocumentVisibilityWidget> createState() =>
      _DocumentVisibilityWidgetState();
}

class _DocumentVisibilityWidgetState extends State<DocumentVisibilityWidget> {
  final I18nService _i18n = I18nService();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _i18n.t('visibility'),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<TrackerVisibilityLevel>(
            initialValue: widget.visibility.level,
            decoration: InputDecoration(
              prefixIcon: Icon(_getVisibilityIcon(widget.visibility.level)),
              border: const OutlineInputBorder(),
            ),
            items: [
              DropdownMenuItem(
                value: TrackerVisibilityLevel.private,
                child: Text(_i18n.t('visibility_private')),
              ),
              DropdownMenuItem(
                value: TrackerVisibilityLevel.public,
                child: Text(_i18n.t('visibility_public')),
              ),
              DropdownMenuItem(
                value: TrackerVisibilityLevel.unlisted,
                child: Text(_i18n.t('visibility_unlisted')),
              ),
              DropdownMenuItem(
                value: TrackerVisibilityLevel.restricted,
                child: Text(_i18n.t('visibility_restricted')),
              ),
            ],
            onChanged: (level) {
              if (level == null) return;
              _onLevelChanged(level);
            },
          ),
          const SizedBox(height: 16),
          // Show share URL for public/unlisted
          if (widget.visibility.level == TrackerVisibilityLevel.public &&
              widget.shareUrl != null)
            _buildShareUrl(widget.shareUrl!),
          if (widget.visibility.level == TrackerVisibilityLevel.unlisted)
            _buildUnlistedUrl(),
          if (widget.visibility.level == TrackerVisibilityLevel.restricted)
            _buildRestrictedInfo(),
        ],
      ),
    );
  }

  void _onLevelChanged(TrackerVisibilityLevel level) {
    TrackerVisibility newVis;
    switch (level) {
      case TrackerVisibilityLevel.private:
        newVis = TrackerVisibility.private;
        break;
      case TrackerVisibilityLevel.public:
        newVis = TrackerVisibility.public;
        break;
      case TrackerVisibilityLevel.unlisted:
        // Preserve existing unlisted ID or generate new one
        final existingId = widget.visibility.unlistedId;
        if (existingId != null &&
            widget.visibility.level == TrackerVisibilityLevel.unlisted) {
          newVis = widget.visibility;
        } else {
          newVis = TrackerVisibility.unlisted(
            unlistedId: _generateUnlistedId(),
            createdAt: DateTime.now().toIso8601String(),
            previousIds: widget.visibility.previousUnlistedIds,
          );
        }
        break;
      case TrackerVisibilityLevel.restricted:
        // Preserve existing allowed contacts/groups
        newVis = TrackerVisibility.restricted(
          contacts: widget.visibility.allowedContacts,
          groups: widget.visibility.allowedGroups,
        );
        break;
    }
    widget.onChanged(newVis);
  }

  Widget _buildShareUrl(String url) {
    return _buildCopyableUrl(url);
  }

  Widget _buildUnlistedUrl() {
    final unlistedId = widget.visibility.unlistedId;
    if (unlistedId == null || widget.shareUrl == null) {
      return const SizedBox.shrink();
    }
    final url = '${widget.shareUrl}?key=$unlistedId';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCopyableUrl(url),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _regenerateUnlistedLink,
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(_i18n.t('regenerate_link')),
        ),
      ],
    );
  }

  Widget _buildCopyableUrl(String url) {
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              url,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.copy, size: 18),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: url));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(_i18n.t('copied_to_clipboard'))),
            );
          },
          tooltip: _i18n.t('copy'),
        ),
      ],
    );
  }

  Widget _buildRestrictedInfo() {
    final contacts = widget.visibility.allowedContacts;
    final groups = widget.visibility.allowedGroups;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (contacts.isNotEmpty)
          Text(
            '${contacts.length} contact${contacts.length != 1 ? "s" : ""} allowed',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (groups.isNotEmpty)
          Text(
            '${groups.length} group${groups.length != 1 ? "s" : ""} allowed',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (contacts.isEmpty && groups.isEmpty)
          Text(
            'No contacts or groups added yet',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
      ],
    );
  }

  void _regenerateUnlistedLink() {
    final previous = <PreviousUnlistedId>[
      ...widget.visibility.previousUnlistedIds,
    ];
    if (widget.visibility.unlistedId != null) {
      previous.add(PreviousUnlistedId(
        id: widget.visibility.unlistedId!,
        invalidatedAt: DateTime.now().toIso8601String(),
      ));
    }
    widget.onChanged(TrackerVisibility.unlisted(
      unlistedId: _generateUnlistedId(),
      createdAt: DateTime.now().toIso8601String(),
      previousIds: previous,
    ));
  }

  String _generateUnlistedId() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  IconData _getVisibilityIcon(TrackerVisibilityLevel level) {
    switch (level) {
      case TrackerVisibilityLevel.private:
        return Icons.lock_outline;
      case TrackerVisibilityLevel.public:
        return Icons.public;
      case TrackerVisibilityLevel.unlisted:
        return Icons.link;
      case TrackerVisibilityLevel.restricted:
        return Icons.group_outlined;
    }
  }
}
