/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

/// Dialog for creating a new forum thread
class NewThreadDialog extends StatefulWidget {
  final List<String> existingThreadTitles;
  final int maxTitleLength;
  final int maxContentLength;

  const NewThreadDialog({
    Key? key,
    required this.existingThreadTitles,
    this.maxTitleLength = 100,
    this.maxContentLength = 5000,
  }) : super(key: key);

  @override
  State<NewThreadDialog> createState() => _NewThreadDialogState();
}

class _NewThreadDialogState extends State<NewThreadDialog> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();
  bool _isCreating = false;

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.topic,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 12),
          const Text('New Thread'),
        ],
      ),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Thread title
                TextFormField(
                  controller: _titleController,
                  decoration: InputDecoration(
                    labelText: 'Thread Title',
                    hintText: 'Enter a descriptive title',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.title),
                    counterText: '${_titleController.text.length}/${widget.maxTitleLength}',
                  ),
                  maxLength: widget.maxTitleLength,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() {}),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Please enter a title';
                    }
                    if (value.trim().length < 5) {
                      return 'Title must be at least 5 characters';
                    }
                    // Check for duplicate titles
                    final normalizedTitle = value.trim().toLowerCase();
                    final isDuplicate = widget.existingThreadTitles.any(
                      (title) => title.toLowerCase() == normalizedTitle,
                    );
                    if (isDuplicate) {
                      return 'A thread with this title already exists';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                // Thread content (original post)
                TextFormField(
                  controller: _contentController,
                  decoration: InputDecoration(
                    labelText: 'Original Post',
                    hintText: 'Write your initial post...',
                    border: const OutlineInputBorder(),
                    alignLabelWithHint: true,
                    counterText: '${_contentController.text.length}/${widget.maxContentLength}',
                  ),
                  maxLines: 10,
                  minLines: 5,
                  maxLength: widget.maxContentLength,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() {}),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Please enter the initial post content';
                    }
                    if (value.trim().length < 10) {
                      return 'Post content must be at least 10 characters';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                // Tips
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.colorScheme.primary.withOpacity(0.3),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.lightbulb_outline,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Tip: Choose a clear, descriptive title that summarizes your topic. This helps others find and understand your thread.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isCreating ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _isCreating ? null : _handleCreate,
          icon: _isCreating
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.add),
          label: const Text('Create Thread'),
        ),
      ],
    );
  }

  /// Handle create button press
  Future<void> _handleCreate() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isCreating = true;
    });

    try {
      final title = _titleController.text.trim();
      final content = _contentController.text.trim();

      // Return the thread data
      if (mounted) {
        Navigator.pop(context, {
          'title': title,
          'content': content,
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error creating thread: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCreating = false;
        });
      }
    }
  }
}
