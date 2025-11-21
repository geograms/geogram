/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/blog_post.dart';
import '../services/i18n_service.dart';

/// Dialog for editing an existing blog post
class EditBlogPostDialog extends StatefulWidget {
  final BlogPost post;

  const EditBlogPostDialog({
    Key? key,
    required this.post,
  }) : super(key: key);

  @override
  State<EditBlogPostDialog> createState() => _EditBlogPostDialogState();
}

class _EditBlogPostDialogState extends State<EditBlogPostDialog> {
  final _formKey = GlobalKey<FormState>();
  final _i18n = I18nService();
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _contentController;
  late final TextEditingController _tagsController;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.post.title);
    _descriptionController = TextEditingController(
      text: widget.post.description ?? '',
    );
    _contentController = TextEditingController(text: widget.post.content);
    _tagsController = TextEditingController(
      text: widget.post.tags.join(', '),
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _contentController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  List<String> _parseTags() {
    if (_tagsController.text.trim().isEmpty) return [];

    return _tagsController.text
        .split(',')
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toList();
  }

  void _update() {
    if (_formKey.currentState!.validate()) {
      Navigator.pop(context, {
        'title': _titleController.text.trim(),
        'description': _descriptionController.text.trim().isNotEmpty
            ? _descriptionController.text.trim()
            : null,
        'content': _contentController.text.trim(),
        'tags': _parseTags(),
        'status': widget.post.status, // Keep current status
      });
    }
  }

  void _updateAndPublish() {
    if (_formKey.currentState!.validate()) {
      Navigator.pop(context, {
        'title': _titleController.text.trim(),
        'description': _descriptionController.text.trim().isNotEmpty
            ? _descriptionController.text.trim()
            : null,
        'content': _contentController.text.trim(),
        'tags': _parseTags(),
        'status': BlogStatus.published, // Change to published
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      child: Container(
        width: 600,
        constraints: const BoxConstraints(maxHeight: 700),
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _i18n.t('edit_blog_post'),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  // Status badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: widget.post.isDraft
                          ? theme.colorScheme.secondaryContainer
                          : theme.colorScheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      widget.post.isDraft ? _i18n.t('draft') : _i18n.t('published'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: widget.post.isDraft
                            ? theme.colorScheme.onSecondaryContainer
                            : theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              // Form fields
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title field
                      TextFormField(
                        controller: _titleController,
                        decoration: InputDecoration(
                          labelText: _i18n.t('title_required_field'),
                          hintText: _i18n.t('enter_post_title'),
                          border: const OutlineInputBorder(),
                        ),
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
                        maxLines: 2,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 16),
                      // Tags field
                      TextFormField(
                        controller: _tagsController,
                        decoration: InputDecoration(
                          labelText: _i18n.t('tags'),
                          hintText: _i18n.t('tags_hint'),
                          border: const OutlineInputBorder(),
                          helperText: _i18n.t('separate_tags_commas'),
                        ),
                        textInputAction: TextInputAction.next,
                      ),
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
                        maxLines: 12,
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return _i18n.t('content_is_required');
                          }
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(_i18n.t('cancel')),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _update,
                    icon: const Icon(Icons.save, size: 18),
                    label: Text(_i18n.t('update')),
                  ),
                  if (widget.post.isDraft) ...[
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _updateAndPublish,
                      icon: const Icon(Icons.publish, size: 18),
                      label: Text(_i18n.t('update_and_publish')),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
