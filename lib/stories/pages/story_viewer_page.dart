/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/i18n_service.dart';
import '../models/story.dart';
import '../models/story_content.dart';
import '../models/story_scene.dart';
import '../models/story_trigger.dart';
import '../services/quiz_state_store.dart';
import '../services/sound_clips_service.dart';
import '../services/stories_storage_service.dart';
import '../widgets/scene_viewer_widget.dart';

/// Page for viewing/playing a story
class StoryViewerPage extends StatefulWidget {
  final Story story;
  final StoriesStorageService storage;
  final I18nService i18n;
  final bool isPreview;

  const StoryViewerPage({
    super.key,
    required this.story,
    required this.storage,
    required this.i18n,
    this.isPreview = false,
  });

  @override
  State<StoryViewerPage> createState() => _StoryViewerPageState();
}

class _StoryViewerPageState extends State<StoryViewerPage> {
  StoryContent? _content;
  StoryScene? _currentScene;
  final List<String> _sceneHistory = [];
  bool _isLoading = true;

  // Auto-advance timer
  Timer? _autoAdvanceTimer;
  int _countdownSeconds = 0;

  // Background music
  Player? _musicPlayer;
  String? _currentMusicTrack;
  final _soundService = SoundClipsService();

  // Quiz persistence
  QuizStateStore? _quizStore;

  // Key to force SceneViewerWidget rebuild on restart
  int _restartKey = 0;

  @override
  void initState() {
    super.initState();
    _initMusicPlayer();
    if (!widget.isPreview) {
      _initQuizStore();
    }
    _loadContent();
  }

  void _initMusicPlayer() {
    _musicPlayer = Player();
    _musicPlayer!.setPlaylistMode(PlaylistMode.loop);

    // Add error listener for debugging
    _musicPlayer!.stream.error.listen((error) {
      debugPrint('StoryViewerPage: Music player error: $error');
    });
  }

  Future<void> _initQuizStore() async {
    _quizStore = QuizStateStore(storiesDir: widget.storage.storiesDir);
    await _quizStore!.initialize();
  }

  @override
  void dispose() {
    _autoAdvanceTimer?.cancel();
    _stopMusic();
    _musicPlayer?.dispose();
    _quizStore?.close();
    super.dispose();
  }

  Future<void> _loadContent() async {
    setState(() => _isLoading = true);
    try {
      await _soundService.init();
      _content = await widget.storage.loadStoryContent(widget.story);
      if (_content != null && _content!.startScene != null) {
        // Start story-level background music
        await _startStoryMusic();
        _navigateToScene(_content!.startSceneId, addToHistory: false);
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _startStoryMusic() async {
    final storyMusic = _content?.settings.backgroundMusic;
    if (storyMusic != null && storyMusic.isNotEmpty) {
      await _playMusic(storyMusic);
    }
  }

  Future<void> _updateSceneMusic(StoryScene scene) async {
    // null = use story music, "" = silence, "path" = override
    if (scene.backgroundMusic == null) {
      // Use story-level music
      final storyMusic = _content?.settings.backgroundMusic;
      if (storyMusic != _currentMusicTrack) {
        if (storyMusic != null && storyMusic.isNotEmpty) {
          await _playMusic(storyMusic);
        } else {
          await _stopMusic();
        }
      }
    } else if (scene.backgroundMusic!.isEmpty) {
      // Silence for this scene
      await _stopMusic();
    } else {
      // Override with scene-specific music
      if (scene.backgroundMusic != _currentMusicTrack) {
        await _playMusic(scene.backgroundMusic!);
      }
    }
  }

  Future<void> _playMusic(String trackFile) async {
    if (_musicPlayer == null) return;

    try {
      final path = _soundService.getTrackPath(trackFile);
      debugPrint('StoryViewerPage: Playing music from: $path');

      // Check file exists
      final file = File(path);
      if (!await file.exists()) {
        debugPrint('StoryViewerPage: Music file not found: $path');
        return;
      }

      await _musicPlayer!.open(Media(path));
      await _musicPlayer!.play();
      _currentMusicTrack = trackFile;
      debugPrint('StoryViewerPage: Music playback started');
    } catch (e) {
      debugPrint('StoryViewerPage: Failed to play music: $e');
    }
  }

  Future<void> _stopMusic() async {
    await _musicPlayer?.stop();
    _currentMusicTrack = null;
  }

  void _navigateToScene(String sceneId, {bool addToHistory = true}) {
    final scene = _content?.getScene(sceneId);
    if (scene == null) return;

    // Cancel existing timer
    _autoAdvanceTimer?.cancel();
    _countdownSeconds = 0;

    // Add current scene to history if requested
    if (addToHistory && _currentScene != null) {
      _sceneHistory.add(_currentScene!.id);
    }

    setState(() {
      _currentScene = scene;
    });

    // Update background music for the scene
    _updateSceneMusic(scene);

    // Start auto-advance timer if configured
    if (scene.autoAdvance != null) {
      _startAutoAdvance(scene.autoAdvance!);
    }
  }

  void _startAutoAdvance(AutoAdvance config) {
    _countdownSeconds = config.delaySeconds;

    _autoAdvanceTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _countdownSeconds--;
      });

      if (_countdownSeconds <= 0) {
        timer.cancel();
        _navigateToScene(config.targetSceneId);
      }
    });
  }

  void _goBack() {
    if (_sceneHistory.isEmpty) return;

    final previousSceneId = _sceneHistory.removeLast();
    _navigateToScene(previousSceneId, addToHistory: false);
  }

  bool get _canGoBack {
    if (_content == null || _currentScene == null) return false;
    if (_sceneHistory.isEmpty) return false;
    return _content!.isBackAllowed(_currentScene!);
  }

  void _handleTrigger(StoryTrigger trigger) {
    switch (trigger.type) {
      case TriggerType.goToScene:
        if (trigger.targetSceneId != null) {
          _navigateToScene(trigger.targetSceneId!);
        }
        break;

      case TriggerType.openUrl:
        if (trigger.url != null) {
          _openUrl(trigger.url!);
        }
        break;

      case TriggerType.playSound:
        if (trigger.soundAsset != null) {
          _playSound(trigger.soundAsset!);
        }
        break;

      case TriggerType.showPopup:
        _showPopup(trigger.popupTitle ?? '', trigger.popupMessage ?? '');
        break;
    }
  }

  void _showPopup(String title, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: title.isNotEmpty ? Text(title) : null,
        content: message.isNotEmpty ? Text(message) : null,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _playSound(String assetRef) async {
    // TODO: Implement sound playback using extracted media file
    // final path = await widget.storage.extractMedia(widget.story, assetRef);
    // if (path != null) { play(path); }
  }

  void _restartStory() {
    if (_content == null) return;
    _quizStore?.clearStory(widget.story.id);
    _autoAdvanceTimer?.cancel();
    _countdownSeconds = 0;
    _sceneHistory.clear();
    setState(() {
      _restartKey++;
    });
    _navigateToScene(_content!.startSceneId, addToHistory: false);
    _startStoryMusic();
  }

  void _exitStory() {
    _stopMusic();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_content == null || _currentScene == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.story.title)),
        body: const Center(child: Text('Failed to load story')),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Scene viewer
          SceneViewerWidget(
            key: ValueKey(_restartKey),
            scene: _currentScene!,
            story: widget.story,
            storage: widget.storage,
            onTrigger: _handleTrigger,
            quizStore: _quizStore,
          ),

          // Top-right controls
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Back button
                if (_canGoBack)
                  _buildControlButton(
                    icon: Icons.arrow_back,
                    onPressed: _goBack,
                    tooltip: widget.i18n.get('back', 'stories'),
                  ),

                const SizedBox(width: 8),

                // Restart button
                _buildControlButton(
                  icon: Icons.refresh,
                  onPressed: _restartStory,
                  tooltip: widget.i18n.get('restart_story', 'stories'),
                ),

                const SizedBox(width: 8),

                // Exit button
                _buildControlButton(
                  icon: Icons.close,
                  onPressed: _exitStory,
                  tooltip: widget.i18n.get('exit_story', 'stories'),
                ),
              ],
            ),
          ),

          // Bottom-right countdown
          if (_countdownSeconds > 0 && (_currentScene?.autoAdvance?.showCountdown ?? true))
            Positioned(
              bottom: MediaQuery.of(context).padding.bottom + 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$_countdownSeconds',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required VoidCallback onPressed,
    required String tooltip,
  }) {
    return Material(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            icon,
            color: Colors.white,
            size: 24,
          ),
        ),
      ),
    );
  }
}
