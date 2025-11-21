/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../services/i18n_service.dart';

/// Dialog for creating a new event update
class NewUpdateDialog extends StatefulWidget {
  const NewUpdateDialog({Key? key}) : super(key: key);

  @override
  State<NewUpdateDialog> createState() => _NewUpdateDialogState();
}

class _NewUpdateDialogState extends State<NewUpdateDialog> {
  final _formKey = GlobalKey<FormState>();
  final _i18n = I18nService();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _create() {
    if (_formKey.currentState!.validate()) {
      Navigator.pop(context, {
        'title': _titleController.text.trim(),
        'content': _contentController.text.trim(),
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      child: Container(
        width: 600,
        constraints: const BoxConstraints(maxHeight: 600),
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              Text(
                _i18n.t('new_update'),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _i18n.t('new_update_description'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),

              // Form fields
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title
                      TextFormField(
                        controller: _titleController,
                        decoration: InputDecoration(
                          labelText: _i18n.t('update_title'),
                          hintText: _i18n.t('enter_update_title'),
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

                      // Content
                      TextFormField(
                        controller: _contentController,
                        decoration: InputDecoration(
                          labelText: _i18n.t('content'),
                          hintText: _i18n.t('enter_update_content'),
                          border: const OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                        maxLines: 10,
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
                  FilledButton.icon(
                    onPressed: _create,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(_i18n.t('create')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
