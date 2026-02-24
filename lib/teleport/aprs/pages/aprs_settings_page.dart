/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * APRS bridge settings — tag subscription management.
 */

import 'package:flutter/material.dart';

import '../aprs_service.dart';

class AprsSettingsPage extends StatefulWidget {
  final String appPath;

  const AprsSettingsPage({super.key, required this.appPath});

  @override
  State<AprsSettingsPage> createState() => _AprsSettingsPageState();
}

class _AprsSettingsPageState extends State<AprsSettingsPage> {
  final TextEditingController _tagController = TextEditingController();

  void _addTag() {
    final text = _tagController.text.trim();
    if (text.isEmpty) return;
    AprsService().addTag(text);
    _tagController.clear();
    setState(() {});
  }

  @override
  void dispose() {
    _tagController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final aprs = AprsService();
    final tags = aprs.subscribedTags.toList()..sort();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('APRS Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Tag subscription section
          Text(
            'Subscribed Tags',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Messages with these hashtags will appear as group channels in the Messages tab.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          // Add new tag
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _tagController,
                  decoration: InputDecoration(
                    hintText: '#tag',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    isDense: true,
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addTag(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _addTag,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Tag list
          if (tags.isEmpty)
            Card(
              child: ListTile(
                leading: Icon(
                  Icons.tag,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                title: const Text('No tags subscribed'),
                subtitle: const Text('Add a tag like #cq or #dev to start'),
              ),
            )
          else
            ...tags.map((tag) => Card(
                  child: ListTile(
                    leading: Icon(
                      Icons.tag,
                      color: theme.colorScheme.primary,
                    ),
                    title: Text(tag),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        aprs.removeTag(tag);
                        setState(() {});
                      },
                    ),
                  ),
                )),
        ],
      ),
    );
  }
}
