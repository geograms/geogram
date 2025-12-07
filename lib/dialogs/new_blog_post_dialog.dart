/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:file_picker/file_picker.dart';
import 'package:latlong2/latlong.dart';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import '../models/blog_post.dart';
import '../services/i18n_service.dart';
import '../pages/location_picker_page.dart';

/// Alias for backwards compatibility
typedef BlogPostPage = NewBlogPostDialog;

/// Full-screen page for creating or editing a blog post
class NewBlogPostDialog extends StatefulWidget {
  final List<String> existingTags;
  final BlogPost? post; // If provided, we're editing an existing post

  const NewBlogPostDialog({
    Key? key,
    this.existingTags = const [],
    this.post,
  }) : super(key: key);

  bool get isEditing => post != null;

  @override
  State<NewBlogPostDialog> createState() => _NewBlogPostDialogState();
}

class _NewBlogPostDialogState extends State<NewBlogPostDialog> {
  final _formKey = GlobalKey<FormState>();
  final _i18n = I18nService();
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _contentController;
  late final TextEditingController _tagsController;
  final _tagsFocusNode = FocusNode();

  List<String> _filteredTags = [];
  bool _showTagSuggestions = false;

  // Attachments
  List<String> _imagePaths = [];
  LatLng? _location;

  @override
  void initState() {
    super.initState();
    // Initialize controllers with existing post data if editing
    _titleController = TextEditingController(text: widget.post?.title ?? '');
    _descriptionController = TextEditingController(text: widget.post?.description ?? '');
    _contentController = TextEditingController(text: widget.post?.content ?? '');
    _tagsController = TextEditingController(
      text: widget.post?.tags.join(', ') ?? '',
    );
    _tagsController.addListener(_onTagsChanged);
    _tagsFocusNode.addListener(_onTagsFocusChanged);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _contentController.dispose();
    _tagsController.removeListener(_onTagsChanged);
    _tagsController.dispose();
    _tagsFocusNode.removeListener(_onTagsFocusChanged);
    _tagsFocusNode.dispose();
    super.dispose();
  }

  void _onTagsFocusChanged() {
    if (_tagsFocusNode.hasFocus) {
      _updateTagSuggestions();
    } else {
      setState(() {
        _showTagSuggestions = false;
      });
    }
  }

  void _onTagsChanged() {
    _updateTagSuggestions();
  }

  void _updateTagSuggestions() {
    final text = _tagsController.text;
    final currentTags = text.split(',').map((t) => t.trim().toLowerCase()).toSet();

    // Get the last tag being typed (after the last comma)
    final lastCommaIndex = text.lastIndexOf(',');
    final currentInput = lastCommaIndex >= 0
        ? text.substring(lastCommaIndex + 1).trim().toLowerCase()
        : text.trim().toLowerCase();

    // Filter existing tags that match and aren't already added
    final suggestions = widget.existingTags.where((tag) {
      final tagLower = tag.toLowerCase();
      final isAlreadyAdded = currentTags.contains(tagLower);
      final matchesInput = currentInput.isEmpty || tagLower.contains(currentInput);
      return !isAlreadyAdded && matchesInput;
    }).toList();

    setState(() {
      _filteredTags = suggestions;
      _showTagSuggestions = _tagsFocusNode.hasFocus && suggestions.isNotEmpty;
    });
  }

  void _addTag(String tag) {
    final text = _tagsController.text;
    final lastCommaIndex = text.lastIndexOf(',');

    String newText;
    if (lastCommaIndex >= 0) {
      // Replace the current input after the last comma
      newText = '${text.substring(0, lastCommaIndex + 1)} $tag, ';
    } else {
      // No comma yet, replace all text
      newText = '$tag, ';
    }

    _tagsController.text = newText;
    _tagsController.selection = TextSelection.fromPosition(
      TextPosition(offset: newText.length),
    );
    _updateTagSuggestions();
  }

  List<String> _parseTags() {
    if (_tagsController.text.trim().isEmpty) return [];

    return _tagsController.text
        .split(',')
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toList();
  }

  Future<void> _pickImages() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        setState(() {
          for (final file in result.files) {
            if (file.path != null && !_imagePaths.contains(file.path)) {
              _imagePaths.add(file.path!);
            }
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('error_picking_file', params: ['$e'])),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  void _removeImage(int index) {
    setState(() {
      _imagePaths.removeAt(index);
    });
  }

  Future<void> _pickLocation() async {
    final result = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(
        builder: (context) => LocationPickerPage(
          initialPosition: _location,
        ),
      ),
    );

    if (result != null && mounted) {
      setState(() {
        _location = result;
      });
    }
  }

  void _removeLocation() {
    setState(() {
      _location = null;
    });
  }

  void _saveAsDraft() {
    if (_formKey.currentState!.validate()) {
      Navigator.pop(context, {
        'title': _titleController.text.trim(),
        'description': _descriptionController.text.trim().isNotEmpty
            ? _descriptionController.text.trim()
            : null,
        'content': _contentController.text.trim(),
        'tags': _parseTags(),
        'status': BlogStatus.draft,
        'imagePaths': _imagePaths,
        'latitude': _location?.latitude,
        'longitude': _location?.longitude,
      });
    }
  }

  void _publish() {
    if (_formKey.currentState!.validate()) {
      Navigator.pop(context, {
        'title': _titleController.text.trim(),
        'description': _descriptionController.text.trim().isNotEmpty
            ? _descriptionController.text.trim()
            : null,
        'content': _contentController.text.trim(),
        'tags': _parseTags(),
        'status': BlogStatus.published,
        'imagePaths': _imagePaths,
        'latitude': _location?.latitude,
        'longitude': _location?.longitude,
      });
    }
  }

  /// Save changes when editing (keeps current status)
  void _update() {
    if (_formKey.currentState!.validate()) {
      Navigator.pop(context, {
        'title': _titleController.text.trim(),
        'description': _descriptionController.text.trim().isNotEmpty
            ? _descriptionController.text.trim()
            : null,
        'content': _contentController.text.trim(),
        'tags': _parseTags(),
        'status': widget.post!.status, // Keep current status
        'imagePaths': _imagePaths,
        'latitude': _location?.latitude,
        'longitude': _location?.longitude,
      });
    }
  }

  Widget _buildAttachmentsSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Action buttons row (using Wrap for narrow screens)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // Add image button
            OutlinedButton.icon(
              onPressed: _pickImages,
              icon: const Icon(Icons.image_outlined, size: 18),
              label: Text(_i18n.t('add_image')),
            ),
            // Add location button
            OutlinedButton.icon(
              onPressed: _pickLocation,
              icon: const Icon(Icons.location_on_outlined, size: 18),
              label: Text(_i18n.t('add_location')),
            ),
          ],
        ),
        // Image previews
        if (_imagePaths.isNotEmpty) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 100,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _imagePaths.length,
              itemBuilder: (context, index) {
                final imagePath = _imagePaths[index];
                return Container(
                  margin: const EdgeInsets.only(right: 8),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: kIsWeb
                            ? Container(
                                width: 100,
                                height: 100,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  Icons.image,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              )
                            : Image.file(
                                File(imagePath) as dynamic,
                                width: 100,
                                height: 100,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return Container(
                                    width: 100,
                                    height: 100,
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Icon(
                                      Icons.broken_image,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  );
                                },
                              ),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: GestureDetector(
                          onTap: () => _removeImage(index),
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface.withOpacity(0.8),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.close,
                              size: 16,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
        // Location preview
        if (_location != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.location_on,
                  color: theme.colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${_location!.latitude.toStringAsFixed(6)}, ${_location!.longitude.toStringAsFixed(6)}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: _removeLocation,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing
            ? _i18n.t('edit_blog_post')
            : _i18n.t('new_blog_post')),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: widget.isEditing
            ? [
                // Status badge for edit mode
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(right: 16),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: widget.post!.isDraft
                          ? theme.colorScheme.secondaryContainer
                          : theme.colorScheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      widget.post!.isDraft
                          ? _i18n.t('draft')
                          : _i18n.t('published'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: widget.post!.isDraft
                            ? theme.colorScheme.onSecondaryContainer
                            : theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ),
              ]
            : null,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Title field
            TextFormField(
              controller: _titleController,
              decoration: InputDecoration(
                labelText: _i18n.t('title_required_field'),
                hintText: _i18n.t('enter_post_title'),
                border: const OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.words,
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return _i18n.t('title_is_required');
                }
                if (value.trim().length < 3) {
                  return _i18n.t('title_min_3_chars');
                }
                return null;
              },
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 16),
            // Description field
            TextFormField(
              controller: _descriptionController,
              decoration: InputDecoration(
                labelText: _i18n.t('description'),
                hintText: _i18n.t('short_description_optional'),
                border: const OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.sentences,
              maxLines: 2,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 16),
            // Tags field with suggestions
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _tagsController,
                  focusNode: _tagsFocusNode,
                  decoration: InputDecoration(
                    labelText: _i18n.t('tags'),
                    hintText: _i18n.t('tags_hint'),
                    border: const OutlineInputBorder(),
                    helperText: _i18n.t('separate_tags_commas'),
                  ),
                  textInputAction: TextInputAction.next,
                ),
                // Tag suggestions
                if (_showTagSuggestions)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    constraints: const BoxConstraints(maxHeight: 120),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: theme.colorScheme.outline.withOpacity(0.5),
                      ),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: _filteredTags.length,
                      itemBuilder: (context, index) {
                        final tag = _filteredTags[index];
                        return InkWell(
                          onTap: () => _addTag(tag),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.tag,
                                  size: 16,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(width: 8),
                                Text(tag),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            // Attachments section
            _buildAttachmentsSection(theme),
            const SizedBox(height: 16),
            // Content field
            TextFormField(
              controller: _contentController,
              decoration: InputDecoration(
                labelText: _i18n.t('content_required'),
                hintText: _i18n.t('write_post_content'),
                border: const OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              maxLines: null,
              minLines: 15,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return _i18n.t('content_is_required');
                }
                return null;
              },
            ),
            // Add some padding at the bottom for the bottom bar
            const SizedBox(height: 80),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 4,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: SafeArea(
          child: widget.isEditing
              ? Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _update,
                        icon: const Icon(Icons.save_outlined),
                        label: Text(_i18n.t('update')),
                      ),
                    ),
                    if (widget.post!.isDraft) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _publish,
                          icon: const Icon(Icons.publish),
                          label: Text(_i18n.t('update_and_publish')),
                        ),
                      ),
                    ],
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _saveAsDraft,
                        icon: const Icon(Icons.save_outlined),
                        label: Text(_i18n.t('save_draft')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _publish,
                        icon: const Icon(Icons.publish),
                        label: Text(_i18n.t('publish')),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
