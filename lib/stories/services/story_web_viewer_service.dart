/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

// Web viewer service for Story NDF documents — generates read-only HTML pages.
// Pure Dart, no Flutter dependencies.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../util/feedback_comment_utils.dart';
import '../../util/html_utils.dart';
import '../../util/nostr_login_scripts.dart';
import '../../util/station_html_templates.dart';
import '../../util/web_feedback_widgets.dart' as feedback;
import '../../work/models/ndf_interaction_settings.dart';
import '../models/story.dart';
import '../models/story_content.dart';
import '../models/story_scene.dart';

/// Entry for the gallery page.
class StoryGalleryEntry {
  final String filename;
  final String title;
  final String? description;
  final List<String> tags;
  final String? thumbnailDataUri;
  final int sceneCount;
  final DateTime modified;

  const StoryGalleryEntry({
    required this.filename,
    required this.title,
    this.description,
    this.tags = const [],
    this.thumbnailDataUri,
    this.sceneCount = 0,
    required this.modified,
  });
}

/// Singleton service for rendering Story NDF documents as HTML pages.
class StoryWebViewerService {
  static final StoryWebViewerService _instance = StoryWebViewerService._internal();
  factory StoryWebViewerService() => _instance;
  StoryWebViewerService._internal();

  /// Build an HTML page for a single story viewer.
  String? buildStoryPage(
    Uint8List ndfBytes, {
    String ownerIdentifier = '',
    String menuItems = '',
    String logoText = '',
    String logoHref = '../',
    NdfInteractionSettings interaction = const NdfInteractionSettings(),
    int likesCount = 0,
    List<String> likedHexPubkeys = const [],
    List<FeedbackComment> comments = const [],
    String ownerNpub = '',
    String storyFilename = '',
  }) {
    try {
      final archive = ZipDecoder().decodeBytes(ndfBytes);

      // Read ndf.json for metadata
      final ndfJson = _readArchiveJson(archive, 'ndf.json');
      if (ndfJson == null) return null;
      final story = Story.fromJson(ndfJson);

      // Read content/main.json
      final mainJson = _readArchiveJson(archive, 'content/main.json');
      if (mainJson == null) return null;

      // Load all scenes
      final scenes = <String, StoryScene>{};
      for (final entry in archive) {
        if (entry.name.startsWith('content/scenes/') &&
            entry.name.endsWith('.json') &&
            entry.isFile) {
          final content = utf8.decode(entry.content as List<int>);
          final sceneJson = jsonDecode(content) as Map<String, dynamic>;
          final scene = StoryScene.fromJson(sceneJson);
          scenes[scene.id] = scene;
        }
      }
      final storyContent = StoryContent.fromJson(mainJson, loadedScenes: scenes);

      // Collect background images as base64 data URIs
      final backgroundDataUris = <String, String>{};
      for (final scene in storyContent.orderedScenes) {
        final bgAsset = scene.background.asset;
        if (bgAsset != null && bgAsset.isNotEmpty) {
          if (!backgroundDataUris.containsKey(bgAsset)) {
            final assetPath = bgAsset.startsWith('asset://') ? bgAsset.substring(8) : bgAsset;
            final imageBytes = _readArchiveFile(archive, assetPath);
            if (imageBytes != null) {
              final ext = assetPath.split('.').last.toLowerCase();
              final mime = _mimeForExtension(ext);
              backgroundDataUris[bgAsset] = 'data:$mime;base64,${base64Encode(imageBytes)}';
            }
          }
        }
      }

      // Build STORY_DATA JSON
      final storyData = _buildStoryData(storyContent, backgroundDataUris);
      final storyDataJson = jsonEncode(storyData);

      // Build page
      return _buildViewerPage(
        story: story,
        storyContent: storyContent,
        storyDataJson: storyDataJson,
        ownerIdentifier: ownerIdentifier,
        menuItems: menuItems,
        logoText: logoText,
        logoHref: logoHref,
        interaction: interaction,
        likesCount: likesCount,
        likedHexPubkeys: likedHexPubkeys,
        comments: comments,
        ownerNpub: ownerNpub,
        storyFilename: storyFilename,
      );
    } catch (e) {
      return null;
    }
  }

  /// Build gallery page listing multiple stories.
  String buildGalleryPage(
    List<StoryGalleryEntry> entries, {
    String ownerIdentifier = '',
    String menuItems = '',
    String logoText = '',
    String logoHref = './',
  }) {
    final nostrHeaderHtml = getNostrLoginHeaderHtml();
    final nostrStyles = getNostrLoginStyles();
    final nostrScripts = getNostrLoginScripts();
    final globalStyles = StationHtmlTemplates.getBaseStyles();

    // Collect unique tags for filter chips
    final allTags = <String>{};
    for (final e in entries) {
      allTags.addAll(e.tags);
    }
    final sortedTags = allTags.toList()..sort();

    final headerHtml = _buildHeader(logoHref, logoText, nostrHeaderHtml, menuItems);

    // Build story cards
    final cardsHtml = StringBuffer();
    for (final entry in entries) {
      final tagsAttr = entry.tags.map((t) => escapeHtml(t.toLowerCase())).join(' ');
      final thumbnail = entry.thumbnailDataUri;
      final thumbHtml = thumbnail != null
          ? '<img src="$thumbnail" alt="${escapeHtml(entry.title)}" class="story-card-thumb">'
          : '<div class="story-card-thumb story-card-thumb-placeholder"></div>';

      cardsHtml.write('''
      <a href="${Uri.encodeComponent(entry.filename)}" class="story-card" data-tags="$tagsAttr">
        $thumbHtml
        <div class="story-card-body">
          <h3 class="story-card-title">${escapeHtml(entry.title)}</h3>
          ${entry.description != null && entry.description!.isNotEmpty ? '<p class="story-card-desc">${escapeHtml(entry.description!)}</p>' : ''}
          <div class="story-card-meta">
            <span>${entry.sceneCount} scene${entry.sceneCount != 1 ? 's' : ''}</span>
          </div>
          ${entry.tags.isNotEmpty ? '<div class="story-card-tags">${entry.tags.map((t) => '<span class="tag">${escapeHtml(t)}</span>').join('')}</div>' : ''}
        </div>
      </a>''');
    }

    // Filter chips HTML
    final chipsHtml = StringBuffer();
    if (sortedTags.isNotEmpty) {
      chipsHtml.write('<div class="filter-chips">');
      chipsHtml.write('<button class="filter-chip active" onclick="filterStories(\'all\')">All</button>');
      for (final tag in sortedTags) {
        chipsHtml.write('<button class="filter-chip" onclick="filterStories(\'${escapeHtml(tag.toLowerCase())}\')">${escapeHtml(tag)}</button>');
      }
      chipsHtml.write('</div>');
    }

    return '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
  <title>Stories${ownerIdentifier.isNotEmpty ? ' - ${escapeHtml(ownerIdentifier)}' : ''}</title>
  <style>$globalStyles
${_getGalleryStyles()}
  </style>
  $nostrStyles
</head>
<body>
<div class="container">
$headerHtml
  <div class="content">
    <h1 class="gallery-title">Stories</h1>
    $chipsHtml
    <div class="stories-grid" id="stories-grid">
      $cardsHtml
    </div>
    ${entries.isEmpty ? '<p class="empty-message">No stories published yet.</p>' : ''}
  </div>
  <footer class="footer">
    <div class="footer__inner">
      <div class="copyright"><span>published via geogram</span></div>
    </div>
  </footer>
</div>
<script>
function filterStories(tag) {
  var cards = document.querySelectorAll('.story-card');
  var chips = document.querySelectorAll('.filter-chip');
  chips.forEach(function(c) { c.classList.remove('active'); });
  event.target.classList.add('active');
  cards.forEach(function(card) {
    if (tag === 'all') { card.style.display = ''; return; }
    var tags = (card.getAttribute('data-tags') || '').split(' ');
    card.style.display = tags.includes(tag) ? '' : 'none';
  });
}
// Reload on Nostr login to refresh restricted stories (skip auto-connect on load)
(function() {
  var ready = false;
  setTimeout(function() { ready = true; }, 2000);
  document.addEventListener('nostr-connected', function() {
    if (ready) location.reload();
  });
})();
</script>
<script>$nostrScripts</script>
</body>
</html>''';
  }

  // ============================================================
  // Private helpers
  // ============================================================

  String _buildHeader(String logoHref, String logoText, String nostrHeaderHtml, String menuItems) {
    return '''
  <header class="header">
    <div class="header__inner">
      <div class="header__logo">
        <a href="$logoHref" style="text-decoration: none;">
          <div class="logo">${escapeHtml(logoText)}</div>
        </a>
      </div>
      $nostrHeaderHtml
    </div>
    ${menuItems.isNotEmpty ? '<nav class="menu"><ul class="menu__inner">$menuItems</ul></nav>' : ''}
  </header>''';
  }

  Map<String, dynamic>? _readArchiveJson(Archive archive, String path) {
    for (final entry in archive) {
      if (entry.name == path && entry.isFile) {
        final content = utf8.decode(entry.content as List<int>);
        return jsonDecode(content) as Map<String, dynamic>;
      }
    }
    return null;
  }

  Uint8List? _readArchiveFile(Archive archive, String path) {
    for (final entry in archive) {
      if (entry.name == path && entry.isFile) {
        return Uint8List.fromList(entry.content as List<int>);
      }
    }
    return null;
  }

  String _mimeForExtension(String ext) {
    switch (ext) {
      case 'png': return 'image/png';
      case 'jpg': case 'jpeg': return 'image/jpeg';
      case 'gif': return 'image/gif';
      case 'webp': return 'image/webp';
      case 'svg': return 'image/svg+xml';
      default: return 'image/png';
    }
  }

  /// Build the STORY_DATA JSON object for the JS runtime.
  Map<String, dynamic> _buildStoryData(
    StoryContent content,
    Map<String, String> backgroundDataUris,
  ) {
    final scenesData = <Map<String, dynamic>>[];
    for (final scene in content.orderedScenes) {
      final elementsData = <Map<String, dynamic>>[];
      for (final el in scene.elements) {
        final (left, top) = el.position.calculatePosition();
        elementsData.add({
          'id': el.id,
          'type': el.type.name,
          'appearAt': el.appearAt,
          'left': left,
          'top': top,
          'width': el.position.widthPercent,
          'height': el.position.heightPercent,
          'properties': el.properties,
        });
      }

      final triggersData = <Map<String, dynamic>>[];
      for (final t in scene.triggers) {
        triggersData.add({
          'id': t.id,
          'type': t.type.name,
          if (t.elementId != null) 'elementId': t.elementId,
          if (t.touchArea != null) 'touchArea': t.touchArea!.name,
          if (t.targetSceneId != null) 'targetSceneId': t.targetSceneId,
          if (t.url != null) 'url': t.url,
          if (t.popupTitle != null) 'popupTitle': t.popupTitle,
          if (t.popupMessage != null) 'popupMessage': t.popupMessage,
        });
      }

      String? bgDataUri;
      final bgAsset = scene.background.asset;
      if (bgAsset != null && backgroundDataUris.containsKey(bgAsset)) {
        bgDataUri = backgroundDataUris[bgAsset];
      }

      scenesData.add({
        'id': scene.id,
        'index': scene.index,
        'title': scene.title,
        'background': {
          'dataUri': bgDataUri,
          'placeholder': scene.background.placeholder,
          'appearAt': scene.background.appearAt,
        },
        'elements': elementsData,
        'triggers': triggersData,
        if (scene.autoAdvance != null) 'autoAdvance': {
          'delay': scene.autoAdvance!.delay,
          'targetSceneId': scene.autoAdvance!.targetSceneId,
          'showCountdown': scene.autoAdvance!.showCountdown,
        },
        'allowBack': scene.allowBack,
      });
    }

    return {
      'startSceneId': content.startSceneId,
      'sceneIds': content.sceneIds,
      'scenes': scenesData,
      'settings': {
        'defaultTransition': content.settings.defaultTransition,
        'transitionDuration': content.settings.transitionDuration,
        'showSceneTitle': content.settings.showSceneTitle,
        'enableSwipeNavigation': content.settings.enableSwipeNavigation,
        'allowBackNavigation': content.settings.allowBackNavigation,
      },
    };
  }

  String _buildViewerPage({
    required Story story,
    required StoryContent storyContent,
    required String storyDataJson,
    required String ownerIdentifier,
    required String menuItems,
    required String logoText,
    required String logoHref,
    required NdfInteractionSettings interaction,
    required int likesCount,
    required List<String> likedHexPubkeys,
    required List<FeedbackComment> comments,
    required String ownerNpub,
    required String storyFilename,
  }) {
    final nostrHeaderHtml = getNostrLoginHeaderHtml();
    final nostrStyles = getNostrLoginStyles();
    final nostrScripts = getNostrLoginScripts();
    final globalStyles = StationHtmlTemplates.getBaseStyles();

    final headerHtml = _buildHeader(logoHref, logoText, nostrHeaderHtml, menuItems);

    return '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1, user-scalable=no">
  <title>${escapeHtml(story.title)}${ownerIdentifier.isNotEmpty ? ' - ${escapeHtml(ownerIdentifier)}' : ''}</title>
  <style>$globalStyles
${_getViewerStyles()}
${feedback.getFeedbackStyles()}
  </style>
  $nostrStyles
</head>
<body>
<div class="container">
$headerHtml
  <div class="story-layout">
    <div class="scene-viewport" id="scene-viewport">
      <div class="scene-container" id="scene-container"></div>
      <div class="scene-title-overlay" id="scene-title-overlay" style="display:none;"></div>
      <div class="countdown-overlay" id="countdown-overlay" style="display:none;"></div>
      <div class="back-button" id="back-button" style="display:none;" onclick="goBack()">\u2190</div>
    </div>
    <div class="story-sidebar">
      ${feedback.buildFeedbackHtml(interaction, likesCount, comments)}
    </div>
  </div>
</div>
<script>
var STORY_DATA = $storyDataJson;
</script>
<script>
${_getViewerScript()}
</script>
${interaction.permitLikes ? feedback.getLikesScript(ownerNpub, likesCount, likedHexPubkeys, storyFilename) : ''}
${interaction.permitComments ? feedback.getCommentsScript(ownerNpub, storyFilename) : ''}
<script>$nostrScripts</script>
</body>
</html>''';
  }

  // ============================================================
  // CSS
  // ============================================================

  String _getGalleryStyles() {
    return '''
.gallery-title {
  color: var(--accent);
  margin: 0 0 16px;
  padding-bottom: 10px;
  border-bottom: 2px dashed var(--accent);
}
.filter-chips {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin-bottom: 20px;
}
.filter-chip {
  background: transparent;
  border: 1px solid var(--border-color);
  color: var(--color);
  padding: 4px 12px;
  border-radius: 16px;
  cursor: pointer;
  font-family: inherit;
  font-size: 0.8rem;
  transition: all 0.15s;
}
.filter-chip:hover { border-color: var(--accent); }
.filter-chip.active { background: var(--accent); color: #000; border-color: var(--accent); }
.stories-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
  gap: 20px;
}
.story-card {
  display: block;
  text-decoration: none;
  color: var(--color);
  border: 1px solid var(--border-color);
  border-radius: 8px;
  overflow: hidden;
  transition: border-color 0.15s, box-shadow 0.15s;
}
.story-card:hover { border-color: var(--accent); box-shadow: var(--shadow); }
.story-card-thumb {
  width: 100%;
  height: 160px;
  object-fit: cover;
  display: block;
  background: var(--accent-alpha-20);
}
.story-card-thumb-placeholder {
  background: linear-gradient(135deg, var(--accent-alpha-20), var(--background));
}
.story-card-body { padding: 12px; }
.story-card-title { margin: 0 0 6px; font-size: 1rem; color: var(--accent); }
.story-card-desc { margin: 0 0 8px; font-size: 0.85rem; opacity: 0.7; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.story-card-meta { font-size: 0.75rem; opacity: 0.5; margin-bottom: 6px; }
.story-card-tags { display: flex; flex-wrap: wrap; gap: 4px; }
.tag { background: var(--accent-alpha-20); color: var(--accent); padding: 2px 8px; border-radius: 10px; font-size: 0.7rem; }
.empty-message { text-align: center; opacity: 0.5; margin-top: 40px; }
''';
  }

  String _getViewerStyles() {
    return '''
.story-layout {
  display: flex;
  flex-direction: row;
  align-items: flex-start;
  justify-content: center;
  gap: 24px;
  padding: 0 16px;
}
.story-sidebar {
  flex: 0 1 320px;
  min-width: 0;
  max-height: 70vh;
  overflow-y: auto;
}
.story-sidebar:empty { display: none; }
.story-sidebar .feedback-section { border-top: none; margin-top: 0; padding-top: 0; }
@media (max-width: 800px) {
  .story-layout { flex-direction: column; align-items: center; gap: 16px; padding: 0; }
  .story-sidebar { flex: none; width: 100%; max-width: 420px; max-height: none; padding: 0 16px 20px; }
}
.scene-viewport {
  position: relative;
  flex: 0 0 auto;
  width: 100%;
  max-width: 420px;
  aspect-ratio: 9 / 16;
  max-height: 70vh;
  overflow: hidden;
  border-radius: 8px;
  background: #000;
}
@media (max-width: 600px) {
  .scene-viewport { max-width: 100%; max-height: 75vh; border-radius: 0; }
}
.scene-container {
  position: absolute;
  inset: 0;
  background-size: cover;
  background-position: center;
  transition: opacity 0.3s ease;
}
.scene-title-overlay {
  position: absolute;
  top: 12px;
  left: 0;
  right: 0;
  text-align: center;
  color: #fff;
  font-size: 0.85rem;
  text-shadow: 0 1px 4px rgba(0,0,0,0.7);
  pointer-events: none;
  z-index: 10;
}
.countdown-overlay {
  position: absolute;
  bottom: 12px;
  right: 16px;
  color: rgba(255,255,255,0.7);
  font-size: 0.8rem;
  z-index: 10;
  pointer-events: none;
}
.back-button {
  position: absolute;
  top: 12px;
  left: 12px;
  width: 36px;
  height: 36px;
  border-radius: 50%;
  background: rgba(0,0,0,0.5);
  color: #fff;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  z-index: 20;
  font-size: 1.2rem;
  transition: background 0.15s;
}
.back-button:hover { background: rgba(0,0,0,0.8); }

/* Story elements */
.story-el {
  position: absolute;
  opacity: 0;
  transition: opacity 0.3s ease;
  box-sizing: border-box;
  pointer-events: auto;
}
.story-el.visible { opacity: 1; }

/* Text element */
.story-el-text {
  color: #fff;
  word-wrap: break-word;
  text-shadow: 0 1px 3px rgba(0,0,0,0.5);
}

/* Title element */
.story-el-title {
  text-shadow: 0 2px 8px rgba(0,0,0,0.6);
}
.story-el-title.font-bold { font-family: 'Arial Black', 'Helvetica Neue', sans-serif; }
.story-el-title.font-serif { font-family: Georgia, 'Times New Roman', serif; }
.story-el-title.font-handwritten { font-family: 'Brush Script MT', 'Segoe Script', cursive; }
.story-el-title.font-retro { font-family: 'Courier New', 'Lucida Console', monospace; }
.story-el-title.font-condensed { font-family: 'Arial Narrow', 'Roboto Condensed', sans-serif; }

/* Button element */
.story-el-button {
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  text-align: center;
  transition: transform 0.1s;
  user-select: none;
}
.story-el-button:active { transform: scale(0.95); }
.btn-rectangle { border-radius: 0; }
.btn-roundedRect { border-radius: 12px; }
.btn-circle { border-radius: 50%; }
.btn-dot {
  width: 16px !important;
  height: 16px !important;
  border-radius: 50%;
  position: relative;
}
.btn-dot .dot-label {
  position: absolute;
  white-space: nowrap;
  font-size: 12px;
  color: #fff;
  text-shadow: 0 1px 3px rgba(0,0,0,0.5);
}
.dot-label-right { left: calc(100% + 6px); }
.dot-label-left { right: calc(100% + 6px); }
.dot-label-top { bottom: calc(100% + 4px); left: 50%; transform: translateX(-50%); }
.dot-label-bottom { top: calc(100% + 4px); left: 50%; transform: translateX(-50%); }
.btn-invisible { opacity: 0 !important; }

/* Quiz element */
.story-el-quiz {
  cursor: pointer;
  user-select: none;
  text-align: center;
  color: #fff;
  text-shadow: 0 1px 4px rgba(0,0,0,0.5);
}
.quiz-question { font-weight: bold; }
.quiz-answer {
  margin-top: 8px;
  opacity: 0;
  transition: opacity 0.3s;
  font-style: italic;
}
.quiz-answer.revealed { opacity: 1; }
.quiz-hint { font-size: 0.7em; opacity: 0.6; margin-top: 4px; }

/* Touch areas */
.touch-area {
  position: absolute;
  cursor: pointer;
  z-index: 5;
}

/* Popup overlay */
.popup-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0,0,0,0.7);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 100;
}
.popup-box {
  background: var(--background, #1a1a1a);
  color: var(--color, #f0f0f0);
  border: 1px solid var(--border-color, #333);
  border-radius: 12px;
  padding: 24px;
  max-width: 400px;
  width: 90%;
  text-align: center;
}
.popup-box h3 { margin: 0 0 12px; color: var(--accent, #ffa86a); }
.popup-box p { margin: 0 0 16px; }
.popup-box button {
  background: var(--accent, #ffa86a);
  color: #000;
  border: none;
  border-radius: 6px;
  padding: 8px 24px;
  cursor: pointer;
  font-family: inherit;
}

''';
  }

  // ============================================================
  // Story Viewer JS Runtime
  // ============================================================

  String _getViewerScript() {
    return r'''
(function() {
  var data = STORY_DATA;
  var scenesById = {};
  data.scenes.forEach(function(s) { scenesById[s.id] = s; });

  var currentSceneId = null;
  var sceneHistory = [];
  var autoAdvanceTimer = null;
  var countdownInterval = null;
  var elementTimers = [];
  var touchStartX = 0;
  var touchStartY = 0;

  function init() {
    goToScene(data.startSceneId);

    // Swipe navigation
    if (data.settings.enableSwipeNavigation) {
      var vp = document.getElementById('scene-viewport');
      vp.addEventListener('touchstart', function(e) {
        touchStartX = e.touches[0].clientX;
        touchStartY = e.touches[0].clientY;
      }, { passive: true });
      vp.addEventListener('touchend', function(e) {
        var dx = e.changedTouches[0].clientX - touchStartX;
        var dy = e.changedTouches[0].clientY - touchStartY;
        if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy) * 1.5) {
          if (dx < 0) navigateNext();
          else navigatePrev();
        }
      }, { passive: true });
    }
  }

  function navigateNext() {
    var idx = data.sceneIds.indexOf(currentSceneId);
    if (idx >= 0 && idx < data.sceneIds.length - 1) {
      goToScene(data.sceneIds[idx + 1]);
    }
  }

  function navigatePrev() {
    if (sceneHistory.length > 0) {
      var prev = sceneHistory.pop();
      renderScene(prev, false);
    }
  }

  window.goToScene = function(sceneId) {
    if (currentSceneId && currentSceneId !== sceneId) {
      sceneHistory.push(currentSceneId);
    }
    renderScene(sceneId, true);
  };

  function renderScene(sceneId, addToHistory) {
    var scene = scenesById[sceneId];
    if (!scene) return;

    // Clear timers
    clearAutoAdvance();
    elementTimers.forEach(function(t) { clearTimeout(t); });
    elementTimers = [];

    currentSceneId = sceneId;
    var container = document.getElementById('scene-container');

    // Apply transition
    container.style.opacity = '0';
    setTimeout(function() {
      // Set background
      if (scene.background.dataUri) {
        container.style.backgroundImage = 'url(' + scene.background.dataUri + ')';
        container.style.backgroundColor = scene.background.placeholder || '#000';
      } else {
        container.style.backgroundImage = 'none';
        container.style.backgroundColor = scene.background.placeholder || '#000';
      }

      // Clear and rebuild elements
      container.innerHTML = '';

      // Render elements
      scene.elements.forEach(function(el) {
        var div = createElementDiv(el, scene);
        container.appendChild(div);
        if (el.appearAt > 0) {
          var t = setTimeout(function() { div.classList.add('visible'); }, el.appearAt);
          elementTimers.push(t);
        } else {
          div.classList.add('visible');
        }
      });

      // Render touch area triggers
      scene.triggers.forEach(function(trigger) {
        if (trigger.touchArea && !trigger.elementId) {
          var area = createTouchArea(trigger);
          container.appendChild(area);
        }
      });

      container.style.opacity = '1';

      // Scene title overlay
      var titleOverlay = document.getElementById('scene-title-overlay');
      if (data.settings.showSceneTitle && scene.title) {
        titleOverlay.textContent = scene.title;
        titleOverlay.style.display = 'block';
      } else {
        titleOverlay.style.display = 'none';
      }

      // Back button
      var backBtn = document.getElementById('back-button');
      var allowBack = scene.allowBack !== null && scene.allowBack !== undefined
          ? scene.allowBack : data.settings.allowBackNavigation;
      backBtn.style.display = (allowBack && sceneHistory.length > 0) ? 'flex' : 'none';

      // Auto-advance
      if (scene.autoAdvance) {
        startAutoAdvance(scene.autoAdvance);
      }
    }, data.settings.transitionDuration || 300);
  }

  function createElementDiv(el, scene) {
    var div = document.createElement('div');
    div.className = 'story-el';
    div.style.left = el.left + '%';
    div.style.top = el.top + '%';
    if (el.width > 0) div.style.width = el.width + '%';
    if (el.height != null) div.style.height = el.height + '%';
    if (el.top > 70) div.style.transform = 'translateY(-100%)';

    var props = el.properties || {};

    switch (el.type) {
      case 'text':
        div.classList.add('story-el-text');
        div.textContent = props.text || '';
        div.style.fontSize = _fontSizePx(props.fontSize) + 'px';
        div.style.fontWeight = props.fontWeight || 'normal';
        div.style.color = props.color || '#fff';
        div.style.textAlign = props.align || 'left';
        if (props.backgroundColor) {
          div.style.backgroundColor = props.backgroundColor;
          div.style.padding = '8px 12px';
          div.style.borderRadius = '6px';
        }
        break;

      case 'title':
        div.classList.add('story-el-title');
        div.classList.add('font-' + (props.font || 'bold'));
        div.textContent = props.text || '';
        div.style.fontSize = '48px';
        div.style.color = props.color || '#FFFF00';
        div.style.textAlign = props.align || 'center';
        if (props.strokeColor) {
          div.style.webkitTextStroke = '1px ' + props.strokeColor;
        }
        if (props.shadowColor) {
          div.style.textShadow = '0 2px 8px ' + props.shadowColor;
        }
        break;

      case 'button':
        div.classList.add('story-el-button');
        var shape = props.shape || 'roundedRect';
        div.classList.add('btn-' + shape);
        if (shape !== 'invisible') {
          div.style.backgroundColor = props.backgroundColor || 'var(--accent, #ffa86a)';
          div.style.color = props.textColor || '#000';
          div.style.padding = shape === 'dot' ? '0' : '10px 20px';
        }
        if (shape === 'dot') {
          div.style.backgroundColor = props.backgroundColor || 'var(--accent, #ffa86a)';
          if (props.label) {
            var lbl = document.createElement('span');
            lbl.className = 'dot-label dot-label-' + (props.labelPosition || 'right');
            lbl.textContent = props.label;
            div.appendChild(lbl);
          }
        } else if (props.label) {
          div.textContent = props.label;
        }
        break;

      case 'quiz':
        div.classList.add('story-el-quiz');
        div.classList.add('font-' + (props.font || 'bold'));
        div.style.color = props.color || '#fff';
        var qDiv = document.createElement('div');
        qDiv.className = 'quiz-question';
        qDiv.textContent = props.question || '';
        div.appendChild(qDiv);
        var aDiv = document.createElement('div');
        aDiv.className = 'quiz-answer';
        aDiv.textContent = props.answer || '';
        div.appendChild(aDiv);
        var hint = document.createElement('div');
        hint.className = 'quiz-hint';
        hint.textContent = 'Tap to reveal';
        div.appendChild(hint);
        div.onclick = function() {
          aDiv.classList.add('revealed');
          hint.style.display = 'none';
        };
        break;
    }

    // Attach trigger if element has one
    var trigger = scene.triggers.find(function(t) { return t.elementId === el.id; });
    if (trigger && el.type !== 'quiz') {
      div.style.cursor = 'pointer';
      div.onclick = function() { handleTrigger(trigger); };
    }

    return div;
  }

  function _fontSizePx(name) {
    switch (name) {
      case 'small': return 14;
      case 'medium': return 18;
      case 'large': return 24;
      case 'xlarge': return 32;
      case 'title': return 48;
      default: return 18;
    }
  }

  function createTouchArea(trigger) {
    var div = document.createElement('div');
    div.className = 'touch-area';
    var pos = _touchAreaPosition(trigger.touchArea);
    div.style.left = pos.left;
    div.style.top = pos.top;
    div.style.width = pos.width;
    div.style.height = pos.height;
    div.onclick = function() { handleTrigger(trigger); };
    return div;
  }

  function _touchAreaPosition(area) {
    switch (area) {
      case 'leftHalf': return { left: '0', top: '0', width: '50%', height: '100%' };
      case 'rightHalf': return { left: '50%', top: '0', width: '50%', height: '100%' };
      case 'topHalf': return { left: '0', top: '0', width: '100%', height: '50%' };
      case 'bottomHalf': return { left: '0', top: '50%', width: '100%', height: '50%' };
      case 'topLeft': return { left: '0', top: '0', width: '50%', height: '50%' };
      case 'topRight': return { left: '50%', top: '0', width: '50%', height: '50%' };
      case 'bottomLeft': return { left: '0', top: '50%', width: '50%', height: '50%' };
      case 'bottomRight': return { left: '50%', top: '50%', width: '50%', height: '50%' };
      case 'center': return { left: '25%', top: '25%', width: '50%', height: '50%' };
      default: return { left: '0', top: '0', width: '100%', height: '100%' };
    }
  }

  window.handleTrigger = function(trigger) {
    switch (trigger.type) {
      case 'goToScene':
        if (trigger.targetSceneId) goToScene(trigger.targetSceneId);
        break;
      case 'openUrl':
        if (trigger.url) window.open(trigger.url, '_blank');
        break;
      case 'playSound':
        // Sound not supported in web viewer
        break;
      case 'showPopup':
        showPopup(trigger.popupTitle || '', trigger.popupMessage || '');
        break;
    }
  };

  function showPopup(title, message) {
    var overlay = document.createElement('div');
    overlay.className = 'popup-overlay';
    overlay.innerHTML = '<div class="popup-box">' +
      (title ? '<h3>' + escapeStr(title) + '</h3>' : '') +
      '<p>' + escapeStr(message) + '</p>' +
      '<button onclick="this.closest(\'.popup-overlay\').remove()">OK</button></div>';
    overlay.onclick = function(e) { if (e.target === overlay) overlay.remove(); };
    document.body.appendChild(overlay);
  }

  function escapeStr(s) {
    var d = document.createElement('div');
    d.textContent = s;
    return d.innerHTML;
  }

  function startAutoAdvance(aa) {
    clearAutoAdvance();
    var remaining = Math.ceil(aa.delay / 1000);
    var cdEl = document.getElementById('countdown-overlay');
    if (aa.showCountdown) {
      cdEl.textContent = remaining + 's';
      cdEl.style.display = 'block';
      countdownInterval = setInterval(function() {
        remaining--;
        if (remaining > 0) cdEl.textContent = remaining + 's';
        else { cdEl.style.display = 'none'; clearInterval(countdownInterval); }
      }, 1000);
    }
    autoAdvanceTimer = setTimeout(function() {
      clearAutoAdvance();
      goToScene(aa.targetSceneId);
    }, aa.delay);
  }

  function clearAutoAdvance() {
    if (autoAdvanceTimer) { clearTimeout(autoAdvanceTimer); autoAdvanceTimer = null; }
    if (countdownInterval) { clearInterval(countdownInterval); countdownInterval = null; }
    var cd = document.getElementById('countdown-overlay');
    if (cd) cd.style.display = 'none';
  }

  window.goBack = function() { navigatePrev(); };

  document.addEventListener('DOMContentLoaded', init);
})();
''';
  }
}
