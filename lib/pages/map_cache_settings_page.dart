/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../services/config_service.dart';
import '../services/i18n_service.dart';
import '../services/map_tile_service.dart';
import '../services/routing_service.dart';
import '../util/geolocation_utils.dart';

/// Settings page for map tile cache configuration
class MapCacheSettingsPage extends StatefulWidget {
  const MapCacheSettingsPage({super.key});

  @override
  State<MapCacheSettingsPage> createState() => _MapCacheSettingsPageState();
}

class _MapCacheSettingsPageState extends State<MapCacheSettingsPage> {
  final I18nService _i18n = I18nService();
  final ConfigService _configService = ConfigService();
  final MapTileService _mapTileService = MapTileService();
  final RoutingService _routingService = RoutingService();

  // Satellite settings
  double _satelliteRadiusKm = 100;
  int _satelliteMaxZoom = 12;

  // Standard map settings
  double _standardRadiusKm = 1000;
  int _standardMaxZoom = 12;

  // Cache freshness
  int _maxAgeMonths = 3;

  // Cache info
  int _cacheSize = 0;
  int _tileCount = 0;

  // Road data info
  int _roadDataSize = 0;
  bool _hasRoadData = false;
  bool _isDownloadingRoads = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadCachedInfoThenRefresh();
    _loadRoadDataInfo();
    // Listen to download progress from the service
    _mapTileService.downloadProgressNotifier.addListener(_onDownloadProgress);
  }

  @override
  void dispose() {
    _mapTileService.downloadProgressNotifier.removeListener(_onDownloadProgress);
    super.dispose();
  }

  void _onDownloadProgress() {
    if (mounted) {
      final progress = _mapTileService.downloadProgressNotifier.value;
      // Show success message when download completes
      if (!progress.isDownloading && progress.downloadedTiles > 0 && progress.error == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('tiles_downloaded',
                params: [progress.downloadedTiles.toString()])),
            backgroundColor: Colors.green,
          ),
        );
        _loadCacheInfo();
      }
      // Show error message if download failed
      if (progress.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_i18n.t('error')}: ${progress.error}'),
            backgroundColor: Colors.red,
          ),
        );
      }
      setState(() {});
    }
  }

  /// Load cached info from disk first, then refresh in background
  void _loadCachedInfoThenRefresh() {
    // Load cached values immediately
    final cachedSize = _configService.getNestedValue('mapCache.lastCacheSize');
    final cachedCount = _configService.getNestedValue('mapCache.lastTileCount');

    if (cachedSize is int && cachedCount is int) {
      setState(() {
        _cacheSize = cachedSize;
        _tileCount = cachedCount;
      });
    }

    // Refresh in background
    _loadCacheInfo();
  }

  void _loadSettings() {
    setState(() {
      final satRadius = _configService.getNestedValue('mapCache.satelliteRadiusKm');
      _satelliteRadiusKm = (satRadius is num) ? satRadius.toDouble() : 100;

      final satZoom = _configService.getNestedValue('mapCache.satelliteMaxZoom');
      _satelliteMaxZoom = (satZoom is int) ? satZoom : 12;

      final stdRadius = _configService.getNestedValue('mapCache.standardRadiusKm');
      _standardRadiusKm = (stdRadius is num) ? stdRadius.toDouble() : 1000;

      final stdZoom = _configService.getNestedValue('mapCache.standardMaxZoom');
      _standardMaxZoom = (stdZoom is int) ? stdZoom : 12;

      final maxAge = _configService.getNestedValue('mapCache.maxAgeMonths');
      _maxAgeMonths = (maxAge is int) ? maxAge : 3;
    });
  }

  void _saveSettings() {
    _configService.setNestedValue(
        'mapCache.satelliteRadiusKm', _satelliteRadiusKm.round());
    _configService.setNestedValue(
        'mapCache.satelliteMaxZoom', _satelliteMaxZoom);
    _configService.setNestedValue(
        'mapCache.standardRadiusKm', _standardRadiusKm.round());
    _configService.setNestedValue(
        'mapCache.standardMaxZoom', _standardMaxZoom);
    _configService.setNestedValue('mapCache.maxAgeMonths', _maxAgeMonths);
  }

  Future<void> _loadCacheInfo({bool isManualRefresh = false}) async {
    try {
      final stats = await _mapTileService.getCacheStatistics();
      if (mounted) {
        final size = stats['sizeBytes'] ?? 0;
        final count = stats['tileCount'] ?? 0;

        // Save to disk for next time
        _configService.setNestedValue('mapCache.lastCacheSize', size);
        _configService.setNestedValue('mapCache.lastTileCount', count);

        setState(() {
          _cacheSize = size;
          _tileCount = count;
        });
      }
    } catch (e) {
      // Silently ignore - will use cached values
    }
  }

  Future<Position?> _getCurrentPosition() async {
    try {
      final result =
          await GeolocationUtils.detectViaGPS(requestPermission: true);
      if (result != null) {
        return Position(
          latitude: result.latitude,
          longitude: result.longitude,
          timestamp: DateTime.now(),
          accuracy: result.accuracy ?? 0,
          altitude: 0,
          altitudeAccuracy: 0,
          heading: 0,
          headingAccuracy: 0,
          speed: 0,
          speedAccuracy: 0,
        );
      }
    } catch (e) {
      // Fall through to return null
    }
    return null;
  }

  Future<void> _loadRoadDataInfo() async {
    final hasData = _routingService.hasRoadData;
    final size = await _routingService.getRoadDataSizeBytes();
    if (mounted) {
      setState(() {
        _hasRoadData = hasData;
        _roadDataSize = size;
      });
    }
  }

  Future<void> _downloadRoadData() async {
    if (_isDownloadingRoads) return;

    final position = await _getCurrentPosition();
    if (position == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('location_required')),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    setState(() => _isDownloadingRoads = true);

    try {
      await _routingService.downloadRoadData(
        lat: position.latitude,
        lon: position.longitude,
        radiusKm: 30,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('road_data_downloaded')),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_i18n.t('route_error')}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isDownloadingRoads = false);
        _loadRoadDataInfo();
      }
    }
  }

  Future<void> _startDownload() async {
    final progress = _mapTileService.downloadProgressNotifier.value;
    if (progress.isDownloading) return;

    _saveSettings();

    final position = await _getCurrentPosition();
    if (position == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('location_required')),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    // Start background download - continues even if user leaves this page
    _mapTileService.startBackgroundDownload(
      lat: position.latitude,
      lng: position.longitude,
      satelliteRadiusKm: _satelliteRadiusKm,
      satelliteMaxZoom: _satelliteMaxZoom,
      standardRadiusKm: _standardRadiusKm,
      standardMaxZoom: _standardMaxZoom,
      maxAgeMonths: _maxAgeMonths,
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _getMaxAgeLabel(int months) {
    if (months == 1) return '1 ${_i18n.t('month')}';
    if (months == 12) return '1 ${_i18n.t('year')}';
    return '$months ${_i18n.t('months')}';
  }

  bool get _isDownloading => _mapTileService.downloadProgressNotifier.value.isDownloading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDownloading = _isDownloading;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(_i18n.t('map_cache')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Satellite Images Section
          _buildSectionHeader(
            theme,
            _i18n.t('satellite_images'),
            Icons.satellite_alt,
          ),
          const SizedBox(height: 12),
          _buildSliderCard(
            theme,
            title: _i18n.t('radius'),
            value: _satelliteRadiusKm,
            min: 100,
            max: 1000,
            divisions: 18,
            unit: 'km',
            onChanged: isDownloading
                ? null
                : (value) {
                    setState(() => _satelliteRadiusKm = value);
                  },
          ),
          const SizedBox(height: 8),
          _buildSliderCard(
            theme,
            title: _i18n.t('detail_level'),
            value: _satelliteMaxZoom.toDouble(),
            min: 8,
            max: 18,
            divisions: 10,
            unit: '',
            formatValue: (v) => _getZoomLabel(v.round()),
            onChanged: isDownloading
                ? null
                : (value) {
                    setState(() => _satelliteMaxZoom = value.round());
                  },
          ),

          const SizedBox(height: 24),

          // Plain Map Section
          _buildSectionHeader(
            theme,
            _i18n.t('plain_map_roads'),
            Icons.map,
          ),
          const SizedBox(height: 12),
          _buildSliderCard(
            theme,
            title: _i18n.t('radius'),
            value: _standardRadiusKm,
            min: 1000,
            max: 3000,
            divisions: 20,
            unit: 'km',
            onChanged: isDownloading
                ? null
                : (value) {
                    setState(() => _standardRadiusKm = value);
                  },
          ),
          const SizedBox(height: 8),
          _buildSliderCard(
            theme,
            title: _i18n.t('detail_level'),
            value: _standardMaxZoom.toDouble(),
            min: 8,
            max: 12,
            divisions: 4,
            unit: '',
            formatValue: (v) => _getZoomLabel(v.round()),
            onChanged: isDownloading
                ? null
                : (value) {
                    setState(() => _standardMaxZoom = value.round());
                  },
          ),

          const SizedBox(height: 24),

          // Cache Freshness Section
          _buildSectionHeader(
            theme,
            _i18n.t('cache_freshness'),
            Icons.schedule,
          ),
          const SizedBox(height: 12),
          _buildMaxAgeSelector(theme),

          const SizedBox(height: 24),

          // Road Data Section
          _buildSectionHeader(
            theme,
            _i18n.t('road_data'),
            Icons.route,
          ),
          const SizedBox(height: 12),
          _buildRoadDataCard(theme),

          const SizedBox(height: 24),

          // Cache Info Card
          _buildCacheInfoCard(theme),

          const SizedBox(height: 24),

          // Download Progress
          ValueListenableBuilder<TileDownloadProgress>(
            valueListenable: _mapTileService.downloadProgressNotifier,
            builder: (context, progress, child) {
              if (progress.isDownloading) {
                return Column(
                  children: [
                    _buildProgressCard(theme, progress),
                    const SizedBox(height: 16),
                  ],
                );
              }
              return const SizedBox.shrink();
            },
          ),

          // Download Button
          ValueListenableBuilder<TileDownloadProgress>(
            valueListenable: _mapTileService.downloadProgressNotifier,
            builder: (context, progress, child) {
              return SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: progress.isDownloading ? null : () => _startDownload(),
                  icon: const Icon(Icons.download),
                  label: Text(_i18n.t('download_tiles')),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildRoadDataCard(ThemeData theme) {
    final info = _routingService.getRoadDataInfo();
    final lastDownloaded = info['lastDownloaded'] as String?;
    final radiusKm = info['radiusKm'] as double?;

    String statusText;
    if (_hasRoadData && lastDownloaded != null) {
      final dt = DateTime.tryParse(lastDownloaded);
      final dateStr = dt != null
          ? '${dt.day}/${dt.month}/${dt.year}'
          : lastDownloaded;
      statusText = '${radiusKm?.round() ?? '?'} km - $dateStr';
    } else {
      statusText = _i18n.t('no_road_data');
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        statusText,
                        style: theme.textTheme.bodyLarge,
                      ),
                      if (_hasRoadData) ...[
                        const SizedBox(height: 4),
                        Text(
                          _formatBytes(_roadDataSize),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_hasRoadData)
                  Icon(Icons.check_circle, color: Colors.green, size: 24),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _isDownloadingRoads ? null : _downloadRoadData,
                icon: _isDownloadingRoads
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download),
                label: Text(_i18n.t('download_road_data')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildSliderCard(
    ThemeData theme, {
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String unit,
    String Function(double)? formatValue,
    void Function(double)? onChanged,
  }) {
    final displayValue =
        formatValue?.call(value) ?? '${value.round()} $unit'.trim();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(title, style: theme.textTheme.bodyLarge),
                Text(
                  displayValue,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
            Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  formatValue?.call(min) ?? '${min.round()} $unit'.trim(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  formatValue?.call(max) ?? '${max.round()} $unit'.trim(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _getZoomLabel(int zoom) {
    if (zoom <= 8) return _i18n.t('overview');
    if (zoom <= 10) return _i18n.t('region');
    if (zoom <= 12) return _i18n.t('city');
    if (zoom <= 14) return _i18n.t('neighborhood');
    if (zoom <= 16) return _i18n.t('street');
    return _i18n.t('detail');
  }

  Widget _buildMaxAgeSelector(ThemeData theme) {
    final options = [1, 3, 6, 9, 12];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _i18n.t('max_cache_age'),
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: options.map((months) {
                final isSelected = _maxAgeMonths == months;
                return ChoiceChip(
                  label: Text(_getMaxAgeLabel(months)),
                  selected: isSelected,
                  onSelected: _isDownloading
                      ? null
                      : (selected) {
                          if (selected) {
                            setState(() => _maxAgeMonths = months);
                          }
                        },
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCacheInfoCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.storage,
                    size: 20, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  _i18n.t('cache'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: () => _loadCacheInfo(isManualRefresh: true),
                  tooltip: _i18n.t('refresh'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildInfoItem(
                    theme,
                    _i18n.t('cache_size'),
                    _formatBytes(_cacheSize),
                  ),
                ),
                Expanded(
                  child: _buildInfoItem(
                    theme,
                    _i18n.t('tile_count'),
                    _tileCount.toString(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _isDownloading
                    ? null
                    : () => _showDeleteConfirmation(context),
                icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                label: Text(
                  _i18n.t('delete_cache'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: theme.colorScheme.error.withValues(alpha: 0.5)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showDeleteConfirmation(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_cache')),
        content: Text(_i18n.t('delete_cache_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _deleteCache();
    }
  }

  Future<void> _deleteCache() async {
    try {
      await _mapTileService.clearCache();

      // Reset metrics to zero
      setState(() {
        _cacheSize = 0;
        _tileCount = 0;
      });

      // Also clear the cached values in config
      _configService.setNestedValue('mapCache.lastCacheSize', 0);
      _configService.setNestedValue('mapCache.lastTileCount', 0);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('cache_deleted')),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_i18n.t('error')}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildInfoItem(ThemeData theme, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildProgressCard(ThemeData theme, TileDownloadProgress downloadProgress) {
    final percentage = (downloadProgress.progress * 100).toStringAsFixed(0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _i18n.t('downloading_tiles'),
                  style: theme.textTheme.bodyLarge,
                ),
                Text(
                  '$percentage%',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: downloadProgress.progress),
            const SizedBox(height: 8),
            Text(
              '${downloadProgress.downloadedTiles} / ${downloadProgress.totalTiles} ${_i18n.t('tiles')}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (downloadProgress.skippedTiles > 0) ...[
              const SizedBox(height: 4),
              Text(
                '${_i18n.t('already_cached')}: ${downloadProgress.skippedTiles}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
