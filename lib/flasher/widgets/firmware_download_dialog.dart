/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/device_definition.dart';
import '../../services/profile_storage.dart';
import '../../util/managed_http_client.dart' show streamDownloadToFile;

/// A single entry from the remote firmware catalog
class CatalogDevice {
  final String project;
  final String architecture;
  final String model;
  final String chip;
  final String title;
  final String description;
  final String path; // Relative path to device.json
  final String? firmwareUrl;
  final String protocol;
  final int baudRate;
  final Map<String, dynamic>? usb;
  final Map<String, dynamic>? media;

  CatalogDevice({
    required this.project,
    required this.architecture,
    required this.model,
    required this.chip,
    required this.title,
    required this.description,
    required this.path,
    this.firmwareUrl,
    this.protocol = 'esptool',
    this.baudRate = 115200,
    this.usb,
    this.media,
  });

  /// Unique key for matching against local hierarchy
  String get hierarchyKey => '$project/$architecture/$model';
}

/// Dialog for browsing and downloading firmware from the remote catalog
class FirmwareDownloadDialog extends StatefulWidget {
  final String basePath;
  final Map<String, Map<String, List<DeviceDefinition>>> hierarchy;
  final ProfileStorage? storage;

  const FirmwareDownloadDialog({
    super.key,
    required this.basePath,
    required this.hierarchy,
    this.storage,
  });

  @override
  State<FirmwareDownloadDialog> createState() => _FirmwareDownloadDialogState();
}

class _FirmwareDownloadDialogState extends State<FirmwareDownloadDialog> {
  static const _baseUrl =
      'https://raw.githubusercontent.com/geograms/geogram/main/downloads/flasher';
  static const _indexUrl = '$_baseUrl/index.json';

  bool _isLoading = true;
  String? _error;
  List<CatalogDevice> _catalog = [];
  String _searchQuery = '';
  String? _downloadingModel;
  String _downloadProgress = '';

  // Track which models have been downloaded in this session
  final Set<String> _sessionDownloaded = {};

  @override
  void initState() {
    super.initState();
    _fetchCatalog();
  }

  Future<void> _fetchCatalog() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await http.get(Uri.parse(_indexUrl));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final catalog = <CatalogDevice>[];

      final projects = json['projects'] as List<dynamic>? ?? [];
      for (final projectJson in projects) {
        final projectId = projectJson['id'] as String;
        final architectures =
            projectJson['architectures'] as List<dynamic>? ?? [];

        for (final archJson in architectures) {
          final archId = archJson['id'] as String;
          final devices = archJson['devices'] as List<dynamic>? ?? [];

          for (final deviceJson in devices) {
            final flash =
                deviceJson['flash'] as Map<String, dynamic>? ?? {};
            catalog.add(CatalogDevice(
              project: projectId,
              architecture: archId,
              model: deviceJson['model'] as String,
              chip: deviceJson['chip'] as String,
              title: deviceJson['title'] as String,
              description: deviceJson['description'] as String? ?? '',
              path: deviceJson['path'] as String,
              firmwareUrl: flash['firmware_url'] as String?,
              protocol: flash['protocol'] as String? ?? 'esptool',
              baudRate: flash['baud_rate'] as int? ?? 115200,
              usb: deviceJson['usb'] as Map<String, dynamic>?,
              media: deviceJson['media'] as Map<String, dynamic>?,
            ));
          }
        }
      }

      setState(() {
        _catalog = catalog;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to fetch catalog: $e';
        _isLoading = false;
      });
    }
  }

  /// Check if a catalog device is already downloaded locally
  bool _isDownloaded(CatalogDevice device) {
    if (_sessionDownloaded.contains(device.hierarchyKey)) return true;

    final archMap = widget.hierarchy[device.project];
    if (archMap == null) return false;
    final devices = archMap[device.architecture];
    if (devices == null) return false;
    return devices.any((d) => d.effectiveModel == device.model);
  }

  /// Get filtered catalog based on search query
  List<CatalogDevice> get _filteredCatalog {
    if (_searchQuery.isEmpty) return _catalog;
    final query = _searchQuery.toLowerCase();
    return _catalog.where((device) {
      return device.title.toLowerCase().contains(query) ||
          device.chip.toLowerCase().contains(query) ||
          device.model.toLowerCase().contains(query) ||
          device.project.toLowerCase().contains(query) ||
          device.architecture.toLowerCase().contains(query) ||
          device.description.toLowerCase().contains(query);
    }).toList();
  }

  Future<void> _downloadDevice(CatalogDevice device) async {
    setState(() {
      _downloadingModel = device.hierarchyKey;
      _downloadProgress = 'Downloading device.json...';
    });

    try {
      final relativeBase =
          '${device.project}/${device.architecture}/${device.model}';
      final storage = widget.storage;

      // 1. Fetch full device.json from remote
      final deviceJsonUrl = '$_baseUrl/${device.path}';
      final deviceResponse = await http.get(Uri.parse(deviceJsonUrl));
      if (deviceResponse.statusCode != 200) {
        throw Exception(
          'Failed to download device.json: HTTP ${deviceResponse.statusCode}',
        );
      }

      final deviceJson =
          jsonDecode(deviceResponse.body) as Map<String, dynamic>;
      final deviceJsonContent =
          const JsonEncoder.withIndent('  ').convert(deviceJson);

      // 2. Create directory and write device.json
      if (storage != null) {
        await storage.createDirectory(relativeBase);
        await storage.writeString(
            '$relativeBase/device.json', deviceJsonContent);
      } else {
        final modelDir = Directory('${widget.basePath}/$relativeBase');
        await modelDir.create(recursive: true);
        await File('${modelDir.path}/device.json')
            .writeAsString(deviceJsonContent);
      }

      // 3. Download media photo if present
      final mediaJson = deviceJson['media'] as Map<String, dynamic>?;
      final photo = mediaJson?['photo'] as String?;
      if (photo != null) {
        setState(() {
          _downloadProgress = 'Downloading photo...';
        });

        final photoUrl =
            '$_baseUrl/$relativeBase/media/$photo';
        final photoResponse = await http.get(Uri.parse(photoUrl));
        if (photoResponse.statusCode == 200) {
          if (storage != null) {
            await storage.createDirectory('$relativeBase/media');
            await storage.writeBytes('$relativeBase/media/$photo',
                Uint8List.fromList(photoResponse.bodyBytes));
          } else {
            final mediaDir =
                Directory('${widget.basePath}/$relativeBase/media');
            await mediaDir.create(recursive: true);
            await File('${mediaDir.path}/$photo')
                .writeAsBytes(photoResponse.bodyBytes);
          }
        }
      }

      // 4. Download firmware binary if URL is available
      final flashJson = deviceJson['flash'] as Map<String, dynamic>?;
      final firmwareUrl = flashJson?['firmware_url'] as String?;
      if (firmwareUrl != null) {
        setState(() {
          _downloadProgress = 'Downloading firmware...';
        });

        final firmwarePath = '${widget.basePath}/$relativeBase/firmware.bin';
        final result = await streamDownloadToFile(
          Uri.parse(firmwareUrl),
          firmwarePath,
          maxBytes: 100 * 1024 * 1024,
        );
        if (!result.success) {
          throw Exception('Failed to download firmware');
        }

        if (storage != null) {
          final bytes = await File(firmwarePath).readAsBytes();
          await storage.writeBytes('$relativeBase/firmware.bin', bytes);
        }
      }

      // Mark as downloaded
      _sessionDownloaded.add(device.hierarchyKey);

      if (mounted) {
        setState(() {
          _downloadingModel = null;
          _downloadProgress = '';
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${device.title} downloaded successfully'),
            backgroundColor: Colors.green,
          ),
        );

        // Auto-close dialog and return downloaded device info
        Navigator.of(context).pop(<String, String>{
          'project': device.project,
          'architecture': device.architecture,
          'model': device.model,
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloadingModel = null;
          _downloadProgress = '';
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Download Firmware'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search by name, chip, project...',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                });
              },
            ),
          ),

          // Content
          Expanded(
            child: _buildContent(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading firmware catalog...'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _fetchCatalog,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final filtered = _filteredCatalog;

    if (filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              _searchQuery.isEmpty
                  ? 'No firmware available'
                  : 'No results for "$_searchQuery"',
              style: TextStyle(color: theme.colorScheme.outline),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: filtered.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final device = filtered[index];
        return _buildDeviceTile(device, theme);
      },
    );
  }

  Widget _buildDeviceTile(CatalogDevice device, ThemeData theme) {
    final isDownloaded = _isDownloaded(device);
    final isDownloading = _downloadingModel == device.hierarchyKey;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      leading: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.blue[50],
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.blue[200]!),
        ),
        child: Text(
          device.chip,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: Colors.blue[800],
          ),
        ),
      ),
      title: Text(
        device.title,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${device.project} / ${device.architecture}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
              fontFamily: 'monospace',
            ),
          ),
          if (device.description.isNotEmpty)
            Text(
              device.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          if (isDownloading)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _downloadProgress,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      trailing: _buildTrailing(device, isDownloaded, isDownloading, theme),
    );
  }

  Widget _buildTrailing(
    CatalogDevice device,
    bool isDownloaded,
    bool isDownloading,
    ThemeData theme,
  ) {
    if (isDownloading) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    if (isDownloaded) {
      return Chip(
        label: const Text('Downloaded'),
        labelStyle: const TextStyle(fontSize: 11, color: Colors.green),
        backgroundColor: Colors.green.withValues(alpha: 0.1),
        side: BorderSide(color: Colors.green.withValues(alpha: 0.3)),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
      );
    }

    return IconButton(
      icon: const Icon(Icons.download),
      tooltip: 'Download ${device.title}',
      onPressed: _downloadingModel != null
          ? null
          : () => _downloadDevice(device),
    );
  }
}
