/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../../services/i18n_service.dart';
import '../models/music_settings.dart';
import '../services/music_storage_service.dart';
import '../services/music_permission_service.dart';

/// Music app settings page
class MusicSettingsPage extends StatefulWidget {
  final MusicSettings settings;
  final MusicStorageService storage;
  final I18nService i18n;

  const MusicSettingsPage({
    super.key,
    required this.settings,
    required this.storage,
    required this.i18n,
  });

  @override
  State<MusicSettingsPage> createState() => _MusicSettingsPageState();
}

class _MusicSettingsPageState extends State<MusicSettingsPage> {
  late MusicSettings _settings;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _settings = widget.settings;
  }

  void _updateSettings(MusicSettings Function(MusicSettings) updater) {
    setState(() {
      _settings = updater(_settings);
      _hasChanges = true;
    });
  }

  Future<void> _saveSettings() async {
    await widget.storage.saveSettings(_settings);
    if (mounted) {
      Navigator.of(context).pop(_settings);
    }
  }

  Future<void> _addSourceFolder() async {
    // Request permission first
    final hasPermission = await MusicPermissionService.requestAudioPermission();
    if (!hasPermission) {
      if (!mounted) return;

      // Check if permanently denied
      final isPermanentlyDenied =
          await MusicPermissionService.isPermanentlyDenied();
      if (isPermanentlyDenied) {
        // Show dialog to open settings
        final openSettings = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(widget.i18n.t('permission_required')),
            content: Text(widget.i18n.t('storage_permission_message')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(widget.i18n.t('cancel')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(widget.i18n.t('open_settings')),
              ),
            ],
          ),
        );
        if (openSettings == true) {
          await MusicPermissionService.openSettings();
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.i18n.t('storage_permission_required'))),
        );
      }
      return;
    }

    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: widget.i18n.t('select_music_folder'),
    );

    if (result != null) {
      final dir = Directory(result);
      if (await dir.exists()) {
        if (!_settings.sourceFolders.contains(result)) {
          _updateSettings(
            (s) => s.copyWith(sourceFolders: [...s.sourceFolders, result]),
          );
          // Auto-save when folder is added
          await widget.storage.saveSettings(_settings);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(widget.i18n.t('folder_already_added'))),
            );
          }
        }
      }
    }
  }

  Future<void> _removeSourceFolder(String folder) async {
    _updateSettings(
      (s) => s.copyWith(
        sourceFolders: s.sourceFolders.where((f) => f != folder).toList(),
      ),
    );
    // Auto-save when folder is removed
    await widget.storage.saveSettings(_settings);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.i18n.t('music_settings')),
        actions: [
          if (_hasChanges)
            TextButton(
              onPressed: _saveSettings,
              child: Text(widget.i18n.t('save')),
            ),
        ],
      ),
      body: ListView(
        children: [
          // Source Folders Section
          _buildSectionHeader(widget.i18n.t('music_folders')),
          if (_settings.sourceFolders.isEmpty)
            ListTile(
              leading: Icon(Icons.info_outline, color: colorScheme.primary),
              title: Text(widget.i18n.t('no_folders_added')),
              subtitle: Text(widget.i18n.t('add_folder_hint')),
            )
          else
            ..._settings.sourceFolders.map(
              (folder) => ListTile(
                leading: const Icon(Icons.folder),
                title: Text(
                  folder.split('/').last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  folder,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => _removeSourceFolder(folder),
                ),
              ),
            ),
          ListTile(
            leading: Icon(Icons.add, color: colorScheme.primary),
            title: Text(
              widget.i18n.t('add_music_folder'),
              style: TextStyle(color: colorScheme.primary),
            ),
            onTap: _addSourceFolder,
          ),
          const Divider(),

          // Scanning Section
          _buildSectionHeader(widget.i18n.t('library')),
          SwitchListTile(
            title: Text(widget.i18n.t('scan_on_startup')),
            subtitle: Text(widget.i18n.t('scan_on_startup_desc')),
            value: _settings.scanOnStartup,
            onChanged: (value) {
              _updateSettings((s) => s.copyWith(scanOnStartup: value));
            },
          ),
          SwitchListTile(
            title: Text(widget.i18n.t('watch_for_changes')),
            subtitle: Text(widget.i18n.t('watch_for_changes_desc')),
            value: _settings.watchFolders,
            onChanged: (value) {
              _updateSettings((s) => s.copyWith(watchFolders: value));
            },
          ),
          SwitchListTile(
            title: Text(widget.i18n.t('group_compilations')),
            subtitle: Text(widget.i18n.t('group_compilations_desc')),
            value: _settings.library.groupCompilations,
            onChanged: (value) {
              _updateSettings(
                (s) => s.copyWith(
                  library: s.library.copyWith(groupCompilations: value),
                ),
              );
            },
          ),
          const Divider(),

          // Playback Section
          _buildSectionHeader(widget.i18n.t('playback')),
          SwitchListTile(
            title: Text(widget.i18n.t('gapless_playback')),
            subtitle: Text(widget.i18n.t('gapless_playback_desc')),
            value: _settings.playback.gapless,
            onChanged: (value) {
              _updateSettings(
                (s) =>
                    s.copyWith(playback: s.playback.copyWith(gapless: value)),
              );
            },
          ),
          ListTile(
            title: Text(widget.i18n.t('crossfade')),
            subtitle: Text(
              widget.i18n.t(
                'crossfade_seconds',
                params: [_settings.playback.crossfadeSeconds.toString()],
              ),
            ),
            trailing: SizedBox(
              width: 150,
              child: Slider(
                value: _settings.playback.crossfadeSeconds.toDouble(),
                min: 0,
                max: 12,
                divisions: 12,
                label: widget.i18n.t(
                  'music_value_seconds_short',
                  params: [_settings.playback.crossfadeSeconds.toString()],
                ),
                onChanged: (value) {
                  _updateSettings(
                    (s) => s.copyWith(
                      playback: s.playback.copyWith(
                        crossfadeSeconds: value.round(),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          ListTile(
            title: Text(widget.i18n.t('replay_gain')),
            subtitle: Text(
              _settings.playback.replayGain == 'off'
                  ? widget.i18n.t('replay_gain_off')
                  : _settings.playback.replayGain == 'track'
                  ? widget.i18n.t('replay_gain_track')
                  : widget.i18n.t('replay_gain_album'),
            ),
            trailing: DropdownButton<String>(
              value: _settings.playback.replayGain,
              items: [
                DropdownMenuItem(
                  value: 'off',
                  child: Text(widget.i18n.t('replay_gain_off')),
                ),
                DropdownMenuItem(
                  value: 'track',
                  child: Text(widget.i18n.t('replay_gain_track')),
                ),
                DropdownMenuItem(
                  value: 'album',
                  child: Text(widget.i18n.t('replay_gain_album')),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  _updateSettings(
                    (s) => s.copyWith(
                      playback: s.playback.copyWith(replayGain: value),
                    ),
                  );
                }
              },
            ),
          ),
          const Divider(),

          // Display Section
          _buildSectionHeader(widget.i18n.t('display')),
          ListTile(
            title: Text(widget.i18n.t('album_sort_order')),
            trailing: DropdownButton<AlbumSortOrder>(
              value: _settings.display.albumSort,
              items: [
                DropdownMenuItem(
                  value: AlbumSortOrder.artist,
                  child: Text(widget.i18n.t('sort_by_artist')),
                ),
                DropdownMenuItem(
                  value: AlbumSortOrder.name,
                  child: Text(widget.i18n.t('sort_by_name')),
                ),
                DropdownMenuItem(
                  value: AlbumSortOrder.year,
                  child: Text(widget.i18n.t('sort_by_year')),
                ),
                DropdownMenuItem(
                  value: AlbumSortOrder.added,
                  child: Text(widget.i18n.t('sort_by_date_added')),
                ),
                DropdownMenuItem(
                  value: AlbumSortOrder.mostPlayed,
                  child: Text(widget.i18n.t('sort_by_most_played')),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  _updateSettings(
                    (s) => s.copyWith(
                      display: s.display.copyWith(albumSort: value),
                    ),
                  );
                }
              },
            ),
          ),
          SwitchListTile(
            title: Text(widget.i18n.t('show_track_numbers')),
            value: _settings.display.showTrackNumbers,
            onChanged: (value) {
              _updateSettings(
                (s) => s.copyWith(
                  display: s.display.copyWith(showTrackNumbers: value),
                ),
              );
            },
          ),
          const Divider(),

          // Online Features Section
          _buildSectionHeader(widget.i18n.t('online_features')),
          SwitchListTile(
            title: Text(widget.i18n.t('auto_download_covers')),
            subtitle: Text(widget.i18n.t('auto_download_covers_desc')),
            value: _settings.online.autoFetchCovers,
            onChanged: (value) {
              _updateSettings(
                (s) => s.copyWith(
                  online: s.online.copyWith(autoFetchCovers: value),
                ),
              );
            },
          ),
          if (_settings.online.autoFetchCovers)
            ListTile(
              title: Text(widget.i18n.t('cover_art_quality')),
              trailing: DropdownButton<String>(
                value: _settings.online.coverSize,
                items: [
                  DropdownMenuItem(
                    value: 'small',
                    child: Text(widget.i18n.t('cover_size_small')),
                  ),
                  DropdownMenuItem(
                    value: 'medium',
                    child: Text(widget.i18n.t('cover_size_medium')),
                  ),
                  DropdownMenuItem(
                    value: 'large',
                    child: Text(widget.i18n.t('cover_size_large')),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    _updateSettings(
                      (s) => s.copyWith(
                        online: s.online.copyWith(coverSize: value),
                      ),
                    );
                  }
                },
              ),
            ),
          SwitchListTile(
            title: Text(widget.i18n.t('auto_detect_genre')),
            subtitle: Text(widget.i18n.t('auto_detect_genre_desc')),
            value: _settings.online.autoDetectGenre,
            onChanged: (value) {
              _updateSettings(
                (s) => s.copyWith(
                  online: s.online.copyWith(autoDetectGenre: value),
                ),
              );
            },
          ),
          SwitchListTile(
            title: Text(widget.i18n.t('auto_fetch_lyrics')),
            subtitle: Text(widget.i18n.t('auto_fetch_lyrics_desc')),
            value: _settings.online.autoFetchLyrics,
            onChanged: (value) {
              _updateSettings(
                (s) => s.copyWith(
                  online: s.online.copyWith(autoFetchLyrics: value),
                ),
              );
            },
          ),
          const Divider(),

          // Cache Section
          _buildSectionHeader(widget.i18n.t('cache')),
          ListTile(
            title: Text(widget.i18n.t('artwork_quality')),
            subtitle: Text(
              widget.i18n.t(
                'music_value_percent',
                params: [_settings.cache.artworkQuality.toString()],
              ),
            ),
            trailing: SizedBox(
              width: 150,
              child: Slider(
                value: _settings.cache.artworkQuality.toDouble(),
                min: 50,
                max: 100,
                divisions: 10,
                label: widget.i18n.t(
                  'music_value_percent',
                  params: [_settings.cache.artworkQuality.toString()],
                ),
                onChanged: (value) {
                  _updateSettings(
                    (s) => s.copyWith(
                      cache: s.cache.copyWith(artworkQuality: value.round()),
                    ),
                  );
                },
              ),
            ),
          ),
          ListTile(
            title: Text(widget.i18n.t('max_cache_size')),
            subtitle: Text(
              widget.i18n.t(
                'music_value_mb',
                params: [_settings.cache.maxCacheSizeMb.toString()],
              ),
            ),
            trailing: SizedBox(
              width: 150,
              child: Slider(
                value: _settings.cache.maxCacheSizeMb.toDouble(),
                min: 100,
                max: 2000,
                divisions: 19,
                label: widget.i18n.t(
                  'music_value_mb',
                  params: [_settings.cache.maxCacheSizeMb.toString()],
                ),
                onChanged: (value) {
                  _updateSettings(
                    (s) => s.copyWith(
                      cache: s.cache.copyWith(maxCacheSizeMb: value.round()),
                    ),
                  );
                },
              ),
            ),
          ),
          ListTile(
            title: Text(widget.i18n.t('clear_artwork_cache')),
            leading: const Icon(Icons.delete_outline),
            onTap: () async {
              await widget.storage.clearArtworkCache();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(widget.i18n.t('artwork_cache_cleared')),
                  ),
                );
              }
            },
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
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
