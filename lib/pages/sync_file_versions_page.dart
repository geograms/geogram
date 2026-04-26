/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

import '../models/sync_file_version.dart';
import '../services/sync_version_service.dart';

class SyncFileVersionsPage extends StatefulWidget {
  const SyncFileVersionsPage({super.key});

  @override
  State<SyncFileVersionsPage> createState() => _SyncFileVersionsPageState();
}

class _SyncFileVersionsPageState extends State<SyncFileVersionsPage> {
  List<SyncFileVersion> _versions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadVersions();
  }

  Future<void> _loadVersions() async {
    final versions = await SyncVersionService.instance.listVersions();
    if (!mounted) return;
    setState(() {
      _versions = versions;
      _loading = false;
    });
  }

  Future<void> _restore(SyncFileVersion version) async {
    final restored = await SyncVersionService.instance.restoreVersion(version.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          restored
              ? 'Restored ${version.folder}/${version.path}'
              : 'Could not restore version',
        ),
      ),
    );
    if (restored) {
      await _loadVersions();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('File versions')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _versions.isEmpty
              ? Center(
                  child: Text(
                    'No saved versions',
                    style: theme.textTheme.bodyLarge,
                  ),
                )
              : ListView.separated(
                  itemCount: _versions.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final version = _versions[index];
                    return ListTile(
                      leading: Icon(
                        version.reason == SyncVersionReason.deleted
                            ? Icons.restore_rounded
                            : Icons.history,
                      ),
                      title: Text(
                        '${version.folder}/${version.path}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${version.reason.name} - ${_formatDate(version.createdAt)} - ${_formatBytes(version.size)}',
                      ),
                      trailing: TextButton(
                        onPressed: () => _restore(version),
                        child: const Text('Restore'),
                      ),
                    );
                  },
                ),
    );
  }

  String _formatDate(DateTime value) {
    final local = value.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(1)} GB';
  }
}
