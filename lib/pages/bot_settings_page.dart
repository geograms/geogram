/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'package:flutter/material.dart';
import '../services/i18n_service.dart';
import '../bot/services/vision_model_manager.dart';
import '../bot/services/music_model_manager.dart';
import '../bot/services/music_storage_service.dart';
import '../bot/models/vision_model_info.dart';
import '../bot/models/music_model_info.dart';

/// Settings page for the Bot assistant
class BotSettingsPage extends StatefulWidget {
  const BotSettingsPage({super.key});

  @override
  State<BotSettingsPage> createState() => _BotSettingsPageState();
}

class _BotSettingsPageState extends State<BotSettingsPage> {
  final I18nService _i18n = I18nService();
  final VisionModelManager _visionModelManager = VisionModelManager();
  final MusicModelManager _musicModelManager = MusicModelManager();
  final MusicStorageService _musicStorage = MusicStorageService();

  // Settings state (placeholder - will be persisted later)
  String _selectedModel = 'none';
  String _selectedWhisperModel = 'tiny';
  bool _voiceInputEnabled = false;
  bool _autoModerationEnabled = true;
  bool _backgroundIndexingEnabled = true;
  String _indexInterval = '30min';
  bool _alertProximityEnabled = true;
  int _alertProximityDistance = 500;

  // Stats (placeholder)
  int _documentsIndexed = 0;
  DateTime? _lastIndexed;
  double _modelsStorageMB = 0;
  double _indexStorageMB = 0;
  double _conversationsStorageMB = 0;

  // Vision model state
  final Map<String, bool> _downloadedModels = {};
  final Map<String, double> _downloadProgress = {};
  final Map<String, StreamSubscription> _downloadSubscriptions = {};
  String _visionStorageUsed = '0 MB';
  StreamSubscription? _downloadStateSubscription;

  // Music model state
  final Map<String, bool> _downloadedMusicModels = {};
  final Map<String, double> _musicDownloadProgress = {};
  final Map<String, StreamSubscription> _musicDownloadSubscriptions = {};
  String _musicModelsStorageUsed = '0 MB';
  String _musicTracksStorageUsed = '0 MB';
  int _savedTracksCount = 0;
  StreamSubscription? _musicDownloadStateSubscription;

  @override
  void initState() {
    super.initState();
    _initializeVisionModels();
    _initializeMusicModels();
  }

  @override
  void dispose() {
    _downloadStateSubscription?.cancel();
    for (final sub in _downloadSubscriptions.values) {
      sub.cancel();
    }
    _musicDownloadStateSubscription?.cancel();
    for (final sub in _musicDownloadSubscriptions.values) {
      sub.cancel();
    }
    super.dispose();
  }

  Future<void> _initializeVisionModels() async {
    await _visionModelManager.initialize();

    // Check which models are downloaded
    for (final model in VisionModels.available) {
      final isDownloaded = await _visionModelManager.isDownloaded(model.id);
      if (mounted) {
        setState(() {
          _downloadedModels[model.id] = isDownloaded;
        });
      }
    }

    // Get storage usage
    final storageUsed = await _visionModelManager.getStorageUsedString();
    if (mounted) {
      setState(() {
        _visionStorageUsed = storageUsed;
      });
    }

    // Listen for download state changes
    _downloadStateSubscription = _visionModelManager.downloadStateChanges.listen((modelId) {
      _refreshVisionModelState();
    });
  }

  Future<void> _refreshVisionModelState() async {
    for (final model in VisionModels.available) {
      final isDownloaded = await _visionModelManager.isDownloaded(model.id);
      if (mounted) {
        setState(() {
          _downloadedModels[model.id] = isDownloaded;
        });
      }
    }

    final storageUsed = await _visionModelManager.getStorageUsedString();
    if (mounted) {
      setState(() {
        _visionStorageUsed = storageUsed;
      });
    }
  }

  Future<void> _initializeMusicModels() async {
    await _musicModelManager.initialize();
    await _musicStorage.initialize();

    // Check which models are downloaded
    for (final model in MusicModels.available) {
      if (!model.isNative) {
        final isDownloaded = await _musicModelManager.isDownloaded(model.id);
        if (mounted) {
          setState(() {
            _downloadedMusicModels[model.id] = isDownloaded;
          });
        }
      }
    }

    // Get storage usage
    final modelsStorage = await _musicModelManager.getStorageUsedString();
    final tracksStorage = await _musicStorage.getStorageUsedString();
    final tracksCount = (await _musicStorage.getSavedTracks()).length;

    if (mounted) {
      setState(() {
        _musicModelsStorageUsed = modelsStorage;
        _musicTracksStorageUsed = tracksStorage;
        _savedTracksCount = tracksCount;
      });
    }

    // Listen for download state changes
    _musicDownloadStateSubscription =
        _musicModelManager.downloadStateChanges.listen((modelId) {
      _refreshMusicModelState();
    });
  }

  Future<void> _refreshMusicModelState() async {
    for (final model in MusicModels.available) {
      if (!model.isNative) {
        final isDownloaded = await _musicModelManager.isDownloaded(model.id);
        if (mounted) {
          setState(() {
            _downloadedMusicModels[model.id] = isDownloaded;
          });
        }
      }
    }

    final modelsStorage = await _musicModelManager.getStorageUsedString();
    final tracksStorage = await _musicStorage.getStorageUsedString();
    final tracksCount = (await _musicStorage.getSavedTracks()).length;

    if (mounted) {
      setState(() {
        _musicModelsStorageUsed = modelsStorage;
        _musicTracksStorageUsed = tracksStorage;
        _savedTracksCount = tracksCount;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('bot_settings')),
      ),
      body: ListView(
        children: [
          // Model Selection
          _buildSectionHeader(_i18n.t('bot_model')),
          _buildModelSelectionTile(colorScheme),

          const Divider(),

          // Vision Models
          _buildSectionHeader(_i18n.t('bot_vision_models')),
          _buildVisionModelsSection(colorScheme),

          const Divider(),

          // Music Generation
          _buildSectionHeader(_i18n.t('bot_music_generation')),
          _buildMusicModelsSection(colorScheme),

          const Divider(),

          // Voice Input
          _buildSectionHeader(_i18n.t('bot_voice_input')),
          _buildWhisperModelTile(),
          SwitchListTile(
            title: Text(_i18n.t('bot_enable_voice')),
            value: _voiceInputEnabled,
            onChanged: (value) {
              setState(() {
                _voiceInputEnabled = value;
              });
            },
          ),

          const Divider(),

          // Features
          _buildSectionHeader(_i18n.t('bot_features')),
          SwitchListTile(
            title: Text(_i18n.t('bot_auto_moderation')),
            subtitle: const Text('Automatically moderate chat room messages'),
            value: _autoModerationEnabled,
            onChanged: (value) {
              setState(() {
                _autoModerationEnabled = value;
              });
            },
          ),
          SwitchListTile(
            title: Text(_i18n.t('bot_background_indexing')),
            subtitle: const Text('Index station data when app is idle'),
            value: _backgroundIndexingEnabled,
            onChanged: (value) {
              setState(() {
                _backgroundIndexingEnabled = value;
              });
            },
          ),
          if (_backgroundIndexingEnabled)
            ListTile(
              title: Text(_i18n.t('bot_index_interval')),
              subtitle: Text(_getIntervalLabel(_indexInterval)),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showIndexIntervalDialog,
            ),

          const Divider(),

          // Alert Proximity
          _buildSectionHeader(_i18n.t('bot_alert_proximity')),
          SwitchListTile(
            title: Text(_i18n.t('bot_alert_proximity_enabled')),
            subtitle: const Text('Get notified when approaching active alerts'),
            value: _alertProximityEnabled,
            onChanged: (value) {
              setState(() {
                _alertProximityEnabled = value;
              });
            },
          ),
          if (_alertProximityEnabled)
            ListTile(
              title: Text(_i18n.t('bot_alert_proximity_distance')),
              subtitle: Text(_i18n.t('bot_alert_proximity_meters').replaceAll('{0}', _alertProximityDistance.toString())),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showAlertDistanceDialog,
            ),

          const Divider(),

          // Index Status
          _buildSectionHeader(_i18n.t('bot_index_status')),
          ListTile(
            title: Text(_i18n.t('bot_documents_indexed')),
            trailing: Text(
              _documentsIndexed.toString(),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
          ListTile(
            title: Text(_i18n.t('bot_last_indexed')),
            trailing: Text(
              _lastIndexed != null
                  ? _formatTimeAgo(_lastIndexed!)
                  : _i18n.t('never'),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.refresh),
              label: Text(_i18n.t('bot_rebuild_index')),
              onPressed: _rebuildIndex,
            ),
          ),

          const Divider(),

          // Storage
          _buildSectionHeader(_i18n.t('bot_storage')),
          ListTile(
            title: Text(_i18n.t('bot_storage_models')),
            trailing: Text(_formatStorageSize(_modelsStorageMB)),
          ),
          ListTile(
            title: Text(_i18n.t('bot_storage_index')),
            trailing: Text(_formatStorageSize(_indexStorageMB)),
          ),
          ListTile(
            title: Text(_i18n.t('bot_storage_conversations')),
            trailing: Text(_formatStorageSize(_conversationsStorageMB)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.delete_outline),
              label: Text(_i18n.t('bot_clear_cache')),
              onPressed: _showClearCacheDialog,
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildModelSelectionTile(ColorScheme colorScheme) {
    final modelInfo = _getModelInfo(_selectedModel);

    return ListTile(
      title: Text(_i18n.t('bot_model_current')),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(modelInfo['name'] ?? 'No model selected'),
          if (modelInfo['size'] != null)
            Text(
              modelInfo['size']!,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                _selectedModel == 'none' ? Icons.warning : Icons.check_circle,
                size: 14,
                color: _selectedModel == 'none' ? Colors.orange : Colors.green,
              ),
              const SizedBox(width: 4),
              Text(
                _selectedModel == 'none'
                    ? _i18n.t('bot_model_not_loaded')
                    : _i18n.t('bot_model_loaded'),
                style: TextStyle(
                  fontSize: 12,
                  color: _selectedModel == 'none' ? Colors.orange : Colors.green,
                ),
              ),
            ],
          ),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: _showModelSelectionDialog,
    );
  }

  Widget _buildVisionModelsSection(ColorScheme colorScheme) {
    // Group models by category
    final modelsByCategory = <String, List<VisionModelInfo>>{};
    for (final model in VisionModels.available) {
      modelsByCategory.putIfAbsent(model.category, () => []).add(model);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Storage info
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.storage, size: 18),
              const SizedBox(width: 8),
              Text(
                '${_i18n.t('bot_vision_storage')}: $_visionStorageUsed',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),

        // Models grouped by category
        for (final category in modelsByCategory.keys) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              _getCategoryLabel(category),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: colorScheme.primary,
              ),
            ),
          ),
          for (final model in modelsByCategory[category]!)
            _buildVisionModelTile(model, colorScheme),
        ],

        // Clear all button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.delete_sweep, size: 18),
            label: Text(_i18n.t('bot_clear_vision_models')),
            onPressed: _showClearVisionModelsDialog,
          ),
        ),
      ],
    );
  }

  Widget _buildMusicModelsSection(ColorScheme colorScheme) {
    // Separate native (FM Synth) from downloadable models
    final nativeModels =
        MusicModels.available.where((m) => m.isNative).toList();
    final downloadableModels =
        MusicModels.available.where((m) => !m.isNative).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Storage info
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.storage, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Models: $_musicModelsStorageUsed',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.music_note, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Saved tracks: $_savedTracksCount ($_musicTracksStorageUsed)',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Native/built-in models
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'Built-in (Always Available)',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: colorScheme.primary,
            ),
          ),
        ),
        for (final model in nativeModels)
          _buildMusicModelTile(model, colorScheme),

        // Downloadable AI models
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'AI Models (Higher Quality)',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: colorScheme.primary,
            ),
          ),
        ),
        for (final model in downloadableModels)
          _buildMusicModelTile(model, colorScheme),

        // Clear tracks button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.delete_sweep, size: 18),
                  label: Text(_i18n.t('bot_clear_music_tracks')),
                  onPressed: _savedTracksCount > 0 ? _showClearMusicTracksDialog : null,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: Text(_i18n.t('bot_clear_music_models')),
                  onPressed: _showClearMusicModelsDialog,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMusicModelTile(MusicModelInfo model, ColorScheme colorScheme) {
    final isNative = model.isNative;
    final isDownloaded = isNative || (_downloadedMusicModels[model.id] ?? false);
    final isDownloading = _musicDownloadProgress.containsKey(model.id);
    final progress = _musicDownloadProgress[model.id] ?? 0.0;

    return ListTile(
      leading: Icon(
        _getMusicModelIcon(model.tier),
        color: isDownloaded ? Colors.green : colorScheme.onSurfaceVariant,
      ),
      title: Text(model.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _getMusicModelDescription(model),
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              if (!isNative)
                Text(
                  model.sizeString,
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              if (!isNative) const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: _getMusicTierColor(model.tier).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  model.tier.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: _getMusicTierColor(model.tier),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'RAM: ${model.minRamMb}MB+',
                style: TextStyle(
                  fontSize: 10,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (isDownloading)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: colorScheme.surfaceContainerHighest,
              ),
            ),
        ],
      ),
      trailing: isNative
          ? Icon(Icons.check_circle, color: Colors.green, size: 20)
          : isDownloading
              ? SizedBox(
                  width: 48,
                  child: Text(
                    '${(progress * 100).toInt()}%',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.primary,
                    ),
                  ),
                )
              : isDownloaded
                  ? IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _deleteMusicModel(model),
                      tooltip: _i18n.t('delete'),
                    )
                  : IconButton(
                      icon: const Icon(Icons.download),
                      onPressed: () => _downloadMusicModel(model),
                      tooltip: _i18n.t('download'),
                    ),
    );
  }

  String _getMusicModelDescription(MusicModelInfo model) {
    if (model.isNative) {
      return 'Instant procedural music - no download needed';
    }
    final speed = model.genSpeedRatio > 0
        ? '~${(1 / model.genSpeedRatio).toStringAsFixed(0)}s per 10s audio'
        : '';
    return '${model.genres.join(", ")} ${speed.isNotEmpty ? "• $speed" : ""}';
  }

  IconData _getMusicModelIcon(String tier) {
    switch (tier) {
      case 'instant':
        return Icons.flash_on;
      case 'lite':
        return Icons.speed;
      case 'standard':
        return Icons.music_note;
      case 'quality':
        return Icons.auto_awesome;
      default:
        return Icons.music_note;
    }
  }

  Color _getMusicTierColor(String tier) {
    switch (tier) {
      case 'instant':
        return Colors.teal;
      case 'lite':
        return Colors.green;
      case 'standard':
        return Colors.blue;
      case 'quality':
        return Colors.purple;
      default:
        return Colors.grey;
    }
  }

  Future<void> _downloadMusicModel(MusicModelInfo model) async {
    if (_musicDownloadProgress.containsKey(model.id)) return;

    setState(() {
      _musicDownloadProgress[model.id] = 0.0;
    });

    try {
      final stream = _musicModelManager.downloadModel(model.id);
      _musicDownloadSubscriptions[model.id] = stream.listen(
        (progress) {
          if (mounted) {
            setState(() {
              _musicDownloadProgress[model.id] = progress;
            });
          }
        },
        onDone: () {
          if (mounted) {
            setState(() {
              _musicDownloadProgress.remove(model.id);
              _downloadedMusicModels[model.id] = true;
            });
            _refreshMusicModelState();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${model.name} ${_i18n.t('downloaded')}'),
                duration: const Duration(seconds: 2),
              ),
            );
          }
          _musicDownloadSubscriptions.remove(model.id);
        },
        onError: (error) {
          if (mounted) {
            setState(() {
              _musicDownloadProgress.remove(model.id);
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${_i18n.t('download_failed')}: $error'),
                backgroundColor: Colors.red,
              ),
            );
          }
          _musicDownloadSubscriptions.remove(model.id);
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _musicDownloadProgress.remove(model.id);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_i18n.t('download_failed')}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteMusicModel(MusicModelInfo model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_model')),
        content:
            Text(_i18n.t('delete_model_confirm').replaceAll('{0}', model.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _musicModelManager.deleteModel(model.id);
      if (mounted) {
        setState(() {
          _downloadedMusicModels[model.id] = false;
        });
        _refreshMusicModelState();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${model.name} ${_i18n.t('deleted')}'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  void _showClearMusicModelsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('bot_clear_music_models')),
        content: Text(_i18n.t('bot_clear_music_models_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _musicModelManager.clearAllModels();
              await _refreshMusicModelState();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(_i18n.t('bot_music_models_cleared')),
                  ),
                );
              }
            },
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );
  }

  void _showClearMusicTracksDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('bot_clear_music_tracks')),
        content: Text(_i18n.t('bot_clear_music_tracks_confirm')
            .replaceAll('{0}', _savedTracksCount.toString())),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _musicStorage.clearAllTracks();
              await _refreshMusicModelState();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(_i18n.t('bot_music_tracks_cleared')),
                  ),
                );
              }
            },
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );
  }

  Widget _buildVisionModelTile(VisionModelInfo model, ColorScheme colorScheme) {
    final isDownloaded = _downloadedModels[model.id] ?? false;
    final isDownloading = _downloadProgress.containsKey(model.id);
    final progress = _downloadProgress[model.id] ?? 0.0;

    return ListTile(
      leading: Icon(
        _getModelIcon(model.category),
        color: isDownloaded ? Colors.green : colorScheme.onSurfaceVariant,
      ),
      title: Text(model.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            model.description,
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Text(
                model.sizeString,
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: _getTierColor(model.tier).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  model.tier.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: _getTierColor(model.tier),
                  ),
                ),
              ),
            ],
          ),
          if (isDownloading)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: colorScheme.surfaceContainerHighest,
              ),
            ),
        ],
      ),
      trailing: isDownloading
          ? SizedBox(
              width: 48,
              child: Text(
                '${(progress * 100).toInt()}%',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.primary,
                ),
              ),
            )
          : isDownloaded
              ? IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _deleteVisionModel(model),
                  tooltip: _i18n.t('delete'),
                )
              : IconButton(
                  icon: const Icon(Icons.download),
                  onPressed: () => _downloadVisionModel(model),
                  tooltip: _i18n.t('download'),
                ),
    );
  }

  String _getCategoryLabel(String category) {
    switch (category) {
      case 'lite':
        return _i18n.t('bot_vision_lite');
      case 'general':
        return _i18n.t('bot_vision_general');
      case 'plant':
        return _i18n.t('bot_vision_plant');
      case 'multilingual':
        return _i18n.t('bot_vision_multilingual');
      default:
        return category;
    }
  }

  IconData _getModelIcon(String category) {
    switch (category) {
      case 'lite':
        return Icons.speed;
      case 'general':
        return Icons.image_search;
      case 'plant':
        return Icons.local_florist;
      case 'multilingual':
        return Icons.translate;
      default:
        return Icons.model_training;
    }
  }

  Color _getTierColor(String tier) {
    switch (tier) {
      case 'lite':
        return Colors.green;
      case 'standard':
        return Colors.blue;
      case 'quality':
        return Colors.purple;
      case 'premium':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  Future<void> _downloadVisionModel(VisionModelInfo model) async {
    if (_downloadProgress.containsKey(model.id)) return;

    setState(() {
      _downloadProgress[model.id] = 0.0;
    });

    try {
      final stream = _visionModelManager.downloadModel(model.id);
      _downloadSubscriptions[model.id] = stream.listen(
        (progress) {
          if (mounted) {
            setState(() {
              _downloadProgress[model.id] = progress;
            });
          }
        },
        onDone: () {
          if (mounted) {
            setState(() {
              _downloadProgress.remove(model.id);
              _downloadedModels[model.id] = true;
            });
            _refreshVisionModelState();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${model.name} ${_i18n.t('downloaded')}'),
                duration: const Duration(seconds: 2),
              ),
            );
          }
          _downloadSubscriptions.remove(model.id);
        },
        onError: (error) {
          if (mounted) {
            setState(() {
              _downloadProgress.remove(model.id);
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${_i18n.t('download_failed')}: $error'),
                backgroundColor: Colors.red,
              ),
            );
          }
          _downloadSubscriptions.remove(model.id);
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloadProgress.remove(model.id);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_i18n.t('download_failed')}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteVisionModel(VisionModelInfo model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_model')),
        content: Text(_i18n.t('delete_model_confirm').replaceAll('{0}', model.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _visionModelManager.deleteModel(model.id);
      if (mounted) {
        setState(() {
          _downloadedModels[model.id] = false;
        });
        _refreshVisionModelState();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${model.name} ${_i18n.t('deleted')}'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  void _showClearVisionModelsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('bot_clear_vision_models')),
        content: Text(_i18n.t('bot_clear_vision_models_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _visionModelManager.clearAllModels();
              await _refreshVisionModelState();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(_i18n.t('bot_vision_models_cleared')),
                  ),
                );
              }
            },
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );
  }

  Widget _buildWhisperModelTile() {
    return ListTile(
      title: Text(_i18n.t('bot_whisper_model')),
      subtitle: Text(_getWhisperModelLabel(_selectedWhisperModel)),
      trailing: const Icon(Icons.chevron_right),
      onTap: _showWhisperModelDialog,
    );
  }

  Map<String, String?> _getModelInfo(String model) {
    switch (model) {
      case 'qwen-0.5b':
        return {'name': 'Qwen2.5-0.5B-Instruct', 'size': '~400 MB'};
      case 'qwen-1.5b':
        return {'name': 'Qwen2.5-1.5B-Instruct', 'size': '~1 GB'};
      case 'llama-3b':
        return {'name': 'Llama-3.2-3B-Instruct', 'size': '~2 GB'};
      case 'mistral-7b':
        return {'name': 'Mistral-7B-Instruct', 'size': '~4 GB'};
      default:
        return {'name': 'No model selected', 'size': null};
    }
  }

  String _getWhisperModelLabel(String model) {
    switch (model) {
      case 'tiny':
        return 'Tiny (~75 MB)';
      case 'base':
        return 'Base (~150 MB)';
      case 'small':
        return 'Small (~500 MB)';
      default:
        return model;
    }
  }

  String _getIntervalLabel(String interval) {
    switch (interval) {
      case '15min':
        return _i18n.t('bot_interval_15min');
      case '30min':
        return _i18n.t('bot_interval_30min');
      case '1hour':
        return _i18n.t('bot_interval_1hour');
      case '2hours':
        return _i18n.t('bot_interval_2hours');
      case 'manual':
        return _i18n.t('bot_interval_manual');
      default:
        return interval;
    }
  }

  String _formatTimeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) {
      return _i18n.t('just_now');
    } else if (diff.inMinutes < 60) {
      return _i18n.t('minutes_ago').replaceAll('{0}', diff.inMinutes.toString());
    } else if (diff.inHours < 24) {
      return _i18n.t('hours_ago').replaceAll('{0}', diff.inHours.toString());
    } else {
      return _i18n.t('days_ago').replaceAll('{0}', diff.inDays.toString());
    }
  }

  String _formatStorageSize(double mb) {
    if (mb < 1) {
      return '${(mb * 1024).toStringAsFixed(0)} KB';
    } else if (mb < 1024) {
      return '${mb.toStringAsFixed(1)} MB';
    } else {
      return '${(mb / 1024).toStringAsFixed(1)} GB';
    }
  }

  void _showModelSelectionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('bot_model_select')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildModelOption('none', 'No model', 'Use basic responses only'),
            _buildModelOption('qwen-0.5b', 'Qwen2.5-0.5B', '~400 MB - Fast, basic'),
            _buildModelOption('qwen-1.5b', 'Qwen2.5-1.5B', '~1 GB - Balanced'),
            _buildModelOption('llama-3b', 'Llama-3.2-3B', '~2 GB - Better quality'),
            _buildModelOption('mistral-7b', 'Mistral-7B', '~4 GB - Best quality'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
        ],
      ),
    );
  }

  Widget _buildModelOption(String value, String title, String subtitle) {
    return RadioListTile<String>(
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      groupValue: _selectedModel,
      onChanged: (newValue) {
        setState(() {
          _selectedModel = newValue!;
        });
        Navigator.pop(context);
        if (newValue != 'none') {
          // TODO: Implement model download
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Model download not yet implemented'),
            ),
          );
        }
      },
    );
  }

  void _showWhisperModelDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('bot_whisper_model')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<String>(
              title: const Text('Tiny'),
              subtitle: const Text('~75 MB - Fastest'),
              value: 'tiny',
              groupValue: _selectedWhisperModel,
              onChanged: (value) {
                setState(() {
                  _selectedWhisperModel = value!;
                });
                Navigator.pop(context);
              },
            ),
            RadioListTile<String>(
              title: const Text('Base'),
              subtitle: const Text('~150 MB - Better accuracy'),
              value: 'base',
              groupValue: _selectedWhisperModel,
              onChanged: (value) {
                setState(() {
                  _selectedWhisperModel = value!;
                });
                Navigator.pop(context);
              },
            ),
            RadioListTile<String>(
              title: const Text('Small'),
              subtitle: const Text('~500 MB - Best accuracy'),
              value: 'small',
              groupValue: _selectedWhisperModel,
              onChanged: (value) {
                setState(() {
                  _selectedWhisperModel = value!;
                });
                Navigator.pop(context);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
        ],
      ),
    );
  }

  void _showIndexIntervalDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('bot_index_interval')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<String>(
              title: Text(_i18n.t('bot_interval_15min')),
              value: '15min',
              groupValue: _indexInterval,
              onChanged: (value) {
                setState(() {
                  _indexInterval = value!;
                });
                Navigator.pop(context);
              },
            ),
            RadioListTile<String>(
              title: Text(_i18n.t('bot_interval_30min')),
              value: '30min',
              groupValue: _indexInterval,
              onChanged: (value) {
                setState(() {
                  _indexInterval = value!;
                });
                Navigator.pop(context);
              },
            ),
            RadioListTile<String>(
              title: Text(_i18n.t('bot_interval_1hour')),
              value: '1hour',
              groupValue: _indexInterval,
              onChanged: (value) {
                setState(() {
                  _indexInterval = value!;
                });
                Navigator.pop(context);
              },
            ),
            RadioListTile<String>(
              title: Text(_i18n.t('bot_interval_2hours')),
              value: '2hours',
              groupValue: _indexInterval,
              onChanged: (value) {
                setState(() {
                  _indexInterval = value!;
                });
                Navigator.pop(context);
              },
            ),
            RadioListTile<String>(
              title: Text(_i18n.t('bot_interval_manual')),
              value: 'manual',
              groupValue: _indexInterval,
              onChanged: (value) {
                setState(() {
                  _indexInterval = value!;
                });
                Navigator.pop(context);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
        ],
      ),
    );
  }

  void _showAlertDistanceDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('bot_alert_proximity_distance')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final distance in [100, 250, 500, 1000])
              RadioListTile<int>(
                title: Text('$distance meters'),
                value: distance,
                groupValue: _alertProximityDistance,
                onChanged: (value) {
                  setState(() {
                    _alertProximityDistance = value!;
                  });
                  Navigator.pop(context);
                },
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
        ],
      ),
    );
  }

  void _rebuildIndex() {
    // TODO: Implement index rebuilding
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_i18n.t('bot_rebuilding_index'))),
    );
  }

  void _showClearCacheDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('bot_clear_cache')),
        content: Text(_i18n.t('bot_clear_cache_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              // TODO: Implement cache clearing
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Cache cleared')),
              );
            },
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );
  }
}
