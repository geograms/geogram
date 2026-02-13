/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../../services/i18n_service.dart';
import '../models/music_models.dart';
import '../services/music_services.dart';
import '../widgets/music_widgets.dart';
import 'album_detail_page.dart';
import 'music_settings_page.dart';

/// Main music app home page
class MusicHomePage extends StatefulWidget {
  final String appPath;
  final String appTitle;
  final I18nService i18n;

  const MusicHomePage({
    super.key,
    required this.appPath,
    required this.appTitle,
    required this.i18n,
  });

  @override
  State<MusicHomePage> createState() => _MusicHomePageState();
}

class _MusicHomePageState extends State<MusicHomePage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  late MusicStorageService _storage;
  late MusicLibraryService _libraryService;
  late MusicPlaybackService _playbackService;

  MusicSettings _settings = MusicSettings();
  MusicLibrary _library = MusicLibrary();
  bool _isLoading = true;
  bool _isScanning = false;
  String? _scanStatus;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    _storage = MusicStorageService(basePath: widget.appPath);
    _libraryService = MusicLibraryService(storage: _storage);
    _playbackService = MusicPlaybackService(storage: _storage);

    _initialize();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _playbackService.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    // Load settings
    _settings = await _storage.loadSettings();

    // Ensure cache directories
    await _storage.ensureCacheDirectories();

    // Load library
    _library = await _libraryService.loadLibrary();

    // Initialize playback
    await _playbackService.initialize(_library);

    setState(() {
      _isLoading = false;
    });

    // Auto-scan if needed
    if (_library.isEmpty && _settings.sourceFolders.isNotEmpty) {
      _scanLibrary();
    }
  }

  Future<void> _scanLibrary() async {
    if (_isScanning || _settings.sourceFolders.isEmpty) return;

    setState(() {
      _isScanning = true;
      _scanStatus = widget.i18n.t('starting_scan');
    });

    try {
      _library = await _libraryService.scanFolders(
        _settings.sourceFolders,
        onProgress: (scanned, total, currentFile) {
          setState(() {
            _scanStatus = widget.i18n.t(
              'scanning_progress',
              params: [scanned.toString(), total.toString()],
            );
          });
        },
        settings: _settings,
      );

      // Re-initialize playback with new library
      await _playbackService.initialize(_library);
    } finally {
      setState(() {
        _isScanning = false;
        _scanStatus = null;
      });
    }
  }

  /// Quick add folder: pick folder, save settings, and start scanning immediately
  Future<void> _addFolderAndScan() async {
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
          // Add folder to settings and save immediately
          _settings = _settings.copyWith(
            sourceFolders: [..._settings.sourceFolders, result],
          );
          await _storage.saveSettings(_settings);

          setState(() {});

          // Start scanning in background
          _scanLibrary();
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

  void _openSettings() async {
    final oldFolders = List<String>.from(_settings.sourceFolders);

    final result = await Navigator.of(context).push<MusicSettings>(
      MaterialPageRoute(
        builder: (context) => MusicSettingsPage(
          settings: _settings,
          storage: _storage,
          i18n: widget.i18n,
        ),
      ),
    );

    if (result != null) {
      final foldersChanged = !_listEquals(oldFolders, result.sourceFolders);

      setState(() {
        _settings = result;
      });

      // Rescan if source folders changed
      if (foldersChanged) {
        _scanLibrary();
      }
    }
  }

  bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _openNowPlaying() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.9,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: NowPlayingWidget(
            playback: _playbackService,
            library: _library,
          ),
        ),
      ),
    );
  }

  void _openAlbum(MusicAlbum album) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AlbumDetailPage(
          album: album,
          library: _library,
          playback: _playbackService,
          i18n: widget.i18n,
          onFetchArtwork: _settings.online.autoFetchCovers
              ? (a) => _libraryService.fetchAlbumArtwork(a)
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.appTitle),
        actions: [
          if (_isScanning)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(colorScheme.primary),
                  ),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _scanLibrary,
              tooltip: widget.i18n.t('rescan_library'),
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: widget.i18n.t('music_tab_home')),
            Tab(text: widget.i18n.t('music_tab_folders')),
            Tab(text: widget.i18n.t('music_tab_playlists')),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Status bar
                if (_scanStatus != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    color: colorScheme.primaryContainer,
                    child: Text(
                      _scanStatus!,
                      style: TextStyle(color: colorScheme.onPrimaryContainer),
                    ),
                  ),
                // Main content
                Expanded(
                  child: _library.isEmpty
                      ? _buildEmptyState()
                      : TabBarView(
                          controller: _tabController,
                          children: [
                            _buildHomeTab(),
                            _buildFoldersTab(),
                            _buildPlaylistsTab(),
                          ],
                        ),
                ),
                // Mini player
                MiniPlayerWidget(
                  playback: _playbackService,
                  onTap: _openNowPlaying,
                ),
              ],
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.library_music,
              size: 80,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 24),
            Text(
              widget.i18n.t('no_music_found'),
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _settings.sourceFolders.isEmpty
                  ? widget.i18n.t('add_folder_get_started')
                  : widget.i18n.t('tap_refresh_to_scan'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _addFolderAndScan,
              icon: const Icon(Icons.folder_open),
              label: Text(widget.i18n.t('add_music_folder')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeTab() {
    return HomeTabWidget(library: _library, playback: _playbackService);
  }

  Widget _buildFoldersTab() {
    return FolderBrowserWidget(
      library: _library,
      playback: _playbackService,
      sourceFolders: _settings.sourceFolders,
      onFetchArtwork: _settings.online.autoFetchCovers
          ? (a) => _libraryService.fetchAlbumArtwork(a)
          : null,
      onAddFolder: _addFolderAndScan,
      onOpenAlbum: _openAlbum,
    );
  }

  Widget _buildPlaylistsTab() {
    // TODO: Implement playlists
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.playlist_play, size: 64),
          const SizedBox(height: 16),
          Text(widget.i18n.t('playlists_coming_soon')),
        ],
      ),
    );
  }
}
