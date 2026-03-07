/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:flutter/material.dart';

import '../models/manga_extension.dart';
import '../services/manga_extension_service.dart';
import '../../services/i18n_service.dart';

/// Settings page for manga extensions management
class MangaSettingsPage extends StatefulWidget {
  final String appPath;
  final I18nService i18n;

  const MangaSettingsPage({
    super.key,
    required this.appPath,
    required this.i18n,
  });

  @override
  State<MangaSettingsPage> createState() => _MangaSettingsPageState();
}

class _MangaSettingsPageState extends State<MangaSettingsPage> {
  final _extensionService = MangaExtensionService();
  List<MangaExtension> _extensions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadExtensions();
  }

  Future<void> _loadExtensions() async {
    if (!_extensionService.isInitialized) {
      final extensionsDir = '${widget.appPath}/manga/extensions';
      await _extensionService.initialize(extensionsDir);
    }

    setState(() {
      _extensions = _extensionService.extensions;
      _loading = false;
    });
  }

  void _addExtension() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add extension'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Extension folder path',
            hintText: '/path/to/extension/folder',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final path = controller.text.trim();
              if (path.isEmpty) return;

              if (!Directory(path).existsSync()) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Directory does not exist')),
                );
                return;
              }

              if (!File('$path/extension.json').existsSync()) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('No extension.json found in directory')),
                );
                return;
              }

              Navigator.pop(ctx);
              try {
                await _extensionService.installExtension(path);
                await _loadExtensions();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Extension installed')),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: $e')),
                  );
                }
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _removeExtension(MangaExtension ext) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove extension'),
        content: Text('Remove "${ext.name}"? Series links to this extension will stop working.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _extensionService.removeExtension(ext.id);
              await _loadExtensions();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Manga Settings'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'Extensions',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                if (_extensions.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'No extensions installed. Tap + to add one.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ..._extensions.map((ext) => ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            Colors.deepPurple.withValues(alpha: 0.2),
                        child: Text(
                          ext.language.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      title: Text(ext.name),
                      subtitle: Text('v${ext.version} - ${ext.baseUrl}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _removeExtension(ext),
                      ),
                    )),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('Add extension'),
                  subtitle: const Text('Import from a folder with extension.json'),
                  onTap: _addExtension,
                ),
              ],
            ),
    );
  }
}
