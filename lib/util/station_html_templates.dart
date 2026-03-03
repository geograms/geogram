/// Shared HTML templates for station server pages
/// Pure Dart - no Flutter dependencies
/// Used by both Flutter embedded and CLI station servers

import 'html_utils.dart';
import 'nostr_login_scripts.dart';

/// Shared HTML templates for station server pages
class StationHtmlTemplates {
  /// Common CSS variables and base styles (Terminimal theme)
  static String getBaseStyles() {
    return '''
/* Terminimal theme */
:root {
  --accent: rgb(255,168,106);
  --accent-alpha-70: rgba(255,168,106,.7);
  --accent-alpha-20: rgba(255,168,106,.2);
  --background: #101010;
  --color: #f0f0f0;
  --border-color: rgba(255,240,224,.125);
  --shadow: 0 4px 6px rgba(0,0,0,.3);
}
@media (prefers-color-scheme: light) {
  :root {
    --accent: rgb(240,128,48);
    --accent-alpha-70: rgba(240,128,48,.7);
    --accent-alpha-20: rgba(240,128,48,.2);
    --background: white;
    --color: #201030;
    --border-color: rgba(0,0,16,.125);
    --shadow: 0 4px 6px rgba(0,0,0,.1);
  }
}
html { box-sizing: border-box; }
*, *:before, *:after { box-sizing: inherit; }
body {
  margin: 0; padding: 0;
  font-family: Hack, DejaVu Sans Mono, Monaco, Consolas, Ubuntu Mono, monospace;
  font-size: 1rem; line-height: 1.54;
  background-color: var(--background); color: var(--color);
  text-rendering: optimizeLegibility;
  -webkit-font-smoothing: antialiased;
}
a { color: inherit; }
h1, h2, h3 { font-weight: bold; line-height: 1.3; }
h1 { font-size: 1.4rem; }
h2 { font-size: 1.2rem; margin: 0 0 20px 0; }
h3 { font-size: 1rem; margin: 0 0 10px 0; color: var(--accent); }

.container {
  display: flex;
  flex-direction: column;
  padding: 40px;
  max-width: 864px;
  min-height: 100vh;
  margin: 0 auto;
}
@media (max-width: 683px) {
  .container { padding: 20px; }
}
.header {
  display: flex;
  flex-direction: column;
  position: relative;
  margin-bottom: 30px;
}
.header__inner {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.header__logo {
  display: flex;
  flex: 1;
}
.header__logo:after {
  content: "";
  background: repeating-linear-gradient(90deg, var(--accent), var(--accent) 2px, transparent 0, transparent 16px);
  display: block;
  width: 100%;
  right: 10px;
}
.logo {
  display: flex;
  align-items: center;
  text-decoration: none;
  background: var(--accent);
  color: #000;
  padding: 5px 10px;
}
.menu { margin: 20px 0; }
.menu__inner {
  display: flex;
  flex-wrap: wrap;
  list-style: none;
  margin: 0;
  padding: 0;
}
.menu__inner li {
  margin-right: 8px;
  margin-bottom: 10px;
  flex: 0 0 auto;
}
.menu__inner li.active a {
  color: var(--accent);
  font-weight: bold;
}
.menu__inner li.separator {
  color: var(--accent-alpha-70);
  margin-right: 8px;
}
.menu__inner a {
  color: inherit;
  text-decoration: none;
}
.menu__inner a:hover { color: var(--accent); }
.main { flex: 1; }

/* Footer */
.footer {
  padding: 30px 0;
  border-top: 1px solid var(--border-color);
  margin-top: auto;
  text-align: center;
  color: var(--accent-alpha-70);
  font-size: 0.9rem;
}
.footer a { color: var(--accent); text-decoration: none; }
.footer a:hover { text-decoration: underline; }
''';
  }

  /// CSS styles specific to download page
  static String getDownloadStyles() {
    return '''
/* Download Sections */
.download-section { margin-bottom: 40px; }
.section-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding-bottom: 15px;
  border-bottom: 1px solid var(--border-color);
  margin-bottom: 20px;
}
.section-header h2 { margin: 0; }
.download-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
  gap: 15px;
}
.download-card {
  display: flex;
  align-items: center;
  gap: 15px;
  background: var(--background);
  border: 1px solid var(--border-color);
  border-radius: 8px;
  padding: 15px;
  text-decoration: none;
  transition: border-color 0.2s ease, box-shadow 0.2s ease;
}
.download-card:hover {
  border-color: var(--accent);
  box-shadow: var(--shadow);
}
.download-icon {
  flex-shrink: 0;
  width: 32px;
  height: 32px;
  color: var(--accent);
}
.download-icon svg {
  width: 100%;
  height: 100%;
}
.download-name {
  font-weight: bold;
  flex-shrink: 0;
  margin-right: 10px;
}
.download-size {
  font-size: 0.85rem;
  color: var(--accent-alpha-70);
}
.download-desc {
  font-size: 0.85rem;
  color: var(--accent-alpha-70);
}

/* Model list */
.model-list { display: flex; flex-direction: column; gap: 10px; }
.model-item {
  display: flex;
  align-items: center;
  gap: 15px;
  padding: 12px 15px;
  background: var(--accent-alpha-20);
  border-radius: 6px;
  text-decoration: none;
  transition: background 0.2s ease;
}
.model-item:hover { background: var(--accent-alpha-70); }
.model-icon {
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 8px;
  background: var(--accent);
  border-radius: 6px;
  min-width: 40px;
  min-height: 40px;
}
.model-icon svg {
  width: 24px;
  height: 24px;
  fill: none;
  stroke: var(--background);
  stroke-width: 2;
  stroke-linecap: round;
  stroke-linejoin: round;
}
.model-name { font-weight: bold; flex: 1; }
.model-size { color: var(--accent-alpha-70); font-size: 0.9rem; min-width: 80px; text-align: right; }
.model-desc { color: var(--accent-alpha-70); font-size: 0.85rem; flex: 2; }

@media (max-width: 600px) {
  .download-grid { grid-template-columns: 1fr 1fr; }
  .model-item { flex-wrap: wrap; }
  .model-desc { width: 100%; margin-top: 5px; }
  .model-size { min-width: auto; }
}
''';
  }

  /// Build download page HTML
  /// [availableAssets] maps asset type (androidApk, linuxDesktop, etc.) to download URL
  /// [availableWhisperModels] list of whisper model definitions that are available
  /// [releaseVersion] the current release version
  /// [releaseNotes] the changelog/release notes from GitHub
  static String buildDownloadPage({
    required String stationName,
    required String menuItems,
    Map<String, String>? availableAssets,
    List<Map<String, dynamic>>? availableWhisperModels,
    String? releaseVersion,
    String? releaseNotes,
  }) {
    // Build platform download cards based on available assets
    final platformCards = _buildPlatformCards(availableAssets);

    // Build whisper models section
    final whisperModelsHtml = _buildWhisperModelsHtml(availableWhisperModels);

    // Build changelog section
    final changelogHtml = releaseNotes != null && releaseNotes.isNotEmpty
        ? '''
      <section class="download-section">
        <div class="section-header">
          <h2>Changelog</h2>
        </div>
        <div class="changelog">
          <pre>${escapeHtml(releaseNotes)}</pre>
        </div>
      </section>
      '''
        : '';

    // Version suffix for header
    final versionSuffix = releaseVersion != null ? ' v$releaseVersion' : '';

    return '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Downloads - ${escapeHtml(stationName)}</title>
  <style>
${getBaseStyles()}
${getDownloadStyles()}
.changelog {
  background: var(--accent-alpha-20);
  border-radius: 6px;
  padding: 15px;
  overflow-x: auto;
}
.changelog pre {
  margin: 0;
  white-space: pre-wrap;
  word-wrap: break-word;
  font-size: 0.9rem;
  line-height: 1.5;
}
  </style>
</head>
<body>
  <div class="container">
    <header class="header">
      <div class="header__inner">
        <div class="header__logo">
          <a href="/" style="text-decoration: none;">
            <div class="logo">${escapeHtml(stationName)}</div>
          </a>
        </div>
      </div>
      <nav class="menu">
        <ul class="menu__inner">
          $menuItems
        </ul>
      </nav>
    </header>

    <main class="main">
      <!-- Application Downloads -->
      <section class="download-section">
        <div class="section-header">
          <h2>Geogram$versionSuffix</h2>
        </div>
        $platformCards
      </section>

      $changelogHtml

      <!-- Speech Recognition Models -->
      $whisperModelsHtml

      <!-- Vision AI Models -->
      <section class="download-section">
        <div class="section-header">
          <h2>Vision AI Models</h2>
        </div>
        <div class="model-list">
          <a href="/bot/models/vision/mobilenet-v3-small.tflite" class="model-item">
            <span class="model-icon"><svg viewBox="0 0 24 24"><path d="M12 3v12m0 0l-4-4m4 4l4-4M5 17v2a2 2 0 002 2h10a2 2 0 002-2v-2"/></svg></span>
            <span class="model-name">MobileNet V3 Small</span>
            <span class="model-size">~10 MB</span>
            <span class="model-desc">Fast image classification</span>
          </a>
          <a href="/bot/models/vision/mobilenet-v4-medium.tflite" class="model-item">
            <span class="model-icon"><svg viewBox="0 0 24 24"><path d="M12 3v12m0 0l-4-4m4 4l4-4M5 17v2a2 2 0 002 2h10a2 2 0 002-2v-2"/></svg></span>
            <span class="model-name">MobileNet V4 Medium</span>
            <span class="model-size">~19 MB</span>
            <span class="model-desc">Better accuracy classification</span>
          </a>
          <a href="/bot/models/vision/efficientdet-lite0.tflite" class="model-item">
            <span class="model-icon"><svg viewBox="0 0 24 24"><path d="M12 3v12m0 0l-4-4m4 4l4-4M5 17v2a2 2 0 002 2h10a2 2 0 002-2v-2"/></svg></span>
            <span class="model-name">EfficientDet Lite</span>
            <span class="model-size">~20 MB</span>
            <span class="model-desc">Object detection</span>
          </a>
          <a href="/bot/models/vision/llava-7b-q4.gguf" class="model-item">
            <span class="model-icon"><svg viewBox="0 0 24 24"><path d="M12 3v12m0 0l-4-4m4 4l4-4M5 17v2a2 2 0 002 2h10a2 2 0 002-2v-2"/></svg></span>
            <span class="model-name">LLaVA 7B (Q4)</span>
            <span class="model-size">~4.1 GB</span>
            <span class="model-desc">Full visual Q&A</span>
          </a>
          <a href="/bot/models/vision/llava-7b-q5.gguf" class="model-item">
            <span class="model-icon"><svg viewBox="0 0 24 24"><path d="M12 3v12m0 0l-4-4m4 4l4-4M5 17v2a2 2 0 002 2h10a2 2 0 002-2v-2"/></svg></span>
            <span class="model-name">LLaVA 7B (Q5)</span>
            <span class="model-size">~4.8 GB</span>
            <span class="model-desc">Better quality visual Q&A</span>
          </a>
        </div>
      </section>
    </main>

    <footer class="footer">
      <span>Powered by Geogram</span>
    </footer>
  </div>
</body>
</html>
''';
  }

  /// Build whisper models HTML section based on available models
  static String _buildWhisperModelsHtml(List<Map<String, dynamic>>? models) {
    if (models == null || models.isEmpty) {
      return '''
      <section class="download-section">
        <div class="section-header">
          <h2>Speech Recognition Models (Whisper)</h2>
        </div>
        <p style="color: var(--accent-alpha-70);">
          No whisper models available yet. The station will sync models automatically.
        </p>
      </section>
      ''';
    }

    final modelItems = models.map((m) {
      final id = m['id'] as String;
      final name = m['name'] as String;
      final size = m['size'] as int;
      final description = m['description'] as String;
      final sizeMb = (size / (1024 * 1024)).round();
      final sizeStr = sizeMb >= 1000 ? '~${(sizeMb / 1024).toStringAsFixed(1)} GB' : '~$sizeMb MB';

      return '''
          <a href="/bot/models/whisper/$id" class="model-item">
            <span class="model-icon"><svg viewBox="0 0 24 24"><path d="M12 3v12m0 0l-4-4m4 4l4-4M5 17v2a2 2 0 002 2h10a2 2 0 002-2v-2"/></svg></span>
            <span class="model-name">$name</span>
            <span class="model-size">$sizeStr</span>
            <span class="model-desc">$description</span>
          </a>
      ''';
    }).join('\n');

    return '''
      <section class="download-section">
        <div class="section-header">
          <h2>Speech Recognition Models (Whisper)</h2>
        </div>
        <div class="model-list">
          $modelItems
        </div>
      </section>
    ''';
  }

  /// Build platform download cards based on available assets
  static String _buildPlatformCards(Map<String, String>? availableAssets) {
    if (availableAssets == null || availableAssets.isEmpty) {
      return '''
        <p style="color: var(--accent-alpha-70);">
          No application binaries available yet. The station will sync releases automatically.
        </p>
      ''';
    }

    final cards = <String>[];

    // Helper to check both camelCase (from UpdateAssetType.name) and kebab-case keys
    String? assetUrl(String camelKey, String kebabKey) =>
        availableAssets[camelKey] ?? availableAssets[kebabKey];

    // SVG icons matching geogram.radio/#downloads
    const androidIcon = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="2" width="14" height="20" rx="2"/><line x1="12" y1="18" x2="12.01" y2="18"/></svg>';
    const linuxIcon = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg>';
    const windowsIcon = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><line x1="3" y1="9" x2="21" y2="9"/><line x1="9" y1="21" x2="9" y2="9"/></svg>';

    // Android APK
    final androidUrl = assetUrl('androidApk', 'android-apk');
    if (androidUrl != null) {
      cards.add(_buildPlatformCard(
        url: androidUrl,
        icon: androidIcon,
        name: 'Android',
        desc: 'APK for Android devices',
      ));
    }

    // Linux Desktop
    final linuxUrl = assetUrl('linuxDesktop', 'linux-desktop');
    if (linuxUrl != null) {
      cards.add(_buildPlatformCard(
        url: linuxUrl,
        icon: linuxIcon,
        name: 'Linux',
        desc: 'tar.gz for Linux x64',
      ));
    }

    // Windows Desktop
    final windowsUrl = assetUrl('windowsDesktop', 'windows-desktop');
    if (windowsUrl != null) {
      cards.add(_buildPlatformCard(
        url: windowsUrl,
        icon: windowsIcon,
        name: 'Windows',
        desc: 'ZIP for Windows x64',
      ));
    }

    // macOS Desktop
    final macosUrl = assetUrl('macosDesktop', 'macos-desktop');
    if (macosUrl != null) {
      cards.add(_buildPlatformCard(
        url: macosUrl,
        icon: linuxIcon,
        name: 'macOS',
        desc: 'ZIP for macOS x64',
      ));
    }

    if (cards.isEmpty) {
      return '''
        <p style="color: var(--accent-alpha-70);">
          No application binaries available yet. The station will sync releases automatically.
        </p>
      ''';
    }

    return '<div class="download-grid">${cards.join('\n')}</div>';
  }

  /// Build a single platform download card
  static String _buildPlatformCard({
    required String url,
    required String icon,
    required String name,
    required String desc,
  }) {
    return '''
          <a href="$url" class="download-card">
            <div class="download-icon">$icon</div>
            <div class="download-name">$name</div>
            <div class="download-desc">$desc</div>
          </a>
    ''';
  }

  /// Build simple navigation HTML for download page
  /// Format: home | download (active)
  static String buildDownloadNavigation({bool isActive = true}) {
    if (isActive) {
      return '''<a href="/">home</a>
        <span class="separator">|</span>
        <span class="active">download</span>''';
    } else {
      return '''<a href="/">home</a>
        <span class="separator">|</span>
        <a href="/download/">download</a>''';
    }
  }

  /// JavaScript for dynamic updates (shared between both servers)
  static String getDynamicUpdateScript() {
    return '''
    // Dynamic updates every 10 seconds
    setInterval(async function() {
      try {
        const response = await fetch('/api/clients');
        const data = await response.json();
        updateDeviceCards(data.clients || []);
      } catch (e) {
        console.error('Failed to refresh devices:', e);
      }
    }, 10000);

    function formatTimeAgo(isoString) {
      const then = new Date(isoString);
      const now = new Date();
      const diff = Math.floor((now - then) / 1000);

      if (diff >= 2592000) { // 30 days
        const months = Math.floor(diff / 2592000);
        return months + (months === 1 ? ' month' : ' months') + ' ago';
      } else if (diff >= 604800) { // 7 days
        const weeks = Math.floor(diff / 604800);
        return weeks + (weeks === 1 ? ' week' : ' weeks') + ' ago';
      } else if (diff >= 86400) {
        const days = Math.floor(diff / 86400);
        return days + (days === 1 ? ' day' : ' days') + ' ago';
      } else if (diff >= 3600) {
        const hours = Math.floor(diff / 3600);
        return hours + (hours === 1 ? ' hour' : ' hours') + ' ago';
      } else if (diff >= 60) {
        const minutes = Math.floor(diff / 60);
        return minutes + (minutes === 1 ? ' minute' : ' minutes') + ' ago';
      } else {
        return 'just now';
      }
    }

    function escapeHtml(text) {
      const div = document.createElement('div');
      div.textContent = text;
      return div.innerHTML;
    }

    function updateDeviceCards(clients) {
      const grid = document.querySelector('.devices-grid');
      const emptyState = document.querySelector('.no-devices');

      if (!grid || !emptyState) return;

      if (clients.length === 0) {
        grid.style.display = 'none';
        emptyState.style.display = 'block';
        return;
      }

      grid.style.display = 'grid';
      emptyState.style.display = 'none';

      // Rebuild device cards
      grid.innerHTML = clients.map(c => {
        const callsign = c.callsign || 'Unknown';
        const nickname = c.nickname || callsign;
        const connType = c.connection_type || 'internet';
        const connLabel = connType.charAt(0).toUpperCase() + connType.slice(1);
        const location = (c.latitude && c.longitude)
          ? ' · ' + c.latitude.toFixed(2) + ', ' + c.longitude.toFixed(2)
          : '';
        return '<a href="/' + callsign + '/" class="device-card">' +
          '<div class="device-header">' +
            '<span class="device-callsign">' + escapeHtml(callsign) + '</span>' +
            '<span class="connection-badge ' + connType + '">' + connLabel + '</span>' +
          '</div>' +
          '<div class="device-nickname">' + escapeHtml(nickname) + '</div>' +
          '<div class="device-meta">' +
            'Connected since ' + formatTimeAgo(c.connected_at) + location +
          '</div>' +
        '</a>';
      }).join('');
    }
''';
  }

  /// NOSTR likes/reactions JavaScript for blog post pages.
  /// Returns a <script> block that handles like/unlike toggling.
  /// Relies on the unified Nostr login component (nostr_login_scripts.dart)
  /// which provides window.nostr via either browser extension or generated keys.
  static String getNostrLikesScript({
    required String postId,
    required String authorNpub,
    required int likesCount,
    required List<String> likedHexPubkeys,
    String apiBase = '../api/blog',
  }) {
    return '''
<script>
(function() {
  const postId = '${escapeHtml(postId)}';
  const authorNpub = '${escapeHtml(authorNpub)}';
  const apiBase = '$apiBase';
  const likedPubkeys = ${toJsonArray(likedHexPubkeys)};
  let userPubkey = null;
  let isLiked = false;

  function onNostrConnected(pubkey) {
    userPubkey = pubkey;
    document.getElementById('feedback-section').style.display = 'flex';
    if (likedPubkeys.includes(pubkey)) {
      isLiked = true;
      updateUI($likesCount);
    }
  }

  function init() {
    // Listen for unified Nostr login connection event
    document.addEventListener('nostr-connected', function(e) {
      onNostrConnected(e.detail.pubkey);
    });
    // If already connected (e.g. auto-reconnect from saved keys)
    if (window.GeogramNostr && window.GeogramNostr.connected && window.GeogramNostr.pubkey) {
      onNostrConnected(window.GeogramNostr.pubkey);
    }
  }

  window.toggleLike = async function() {
    if (!userPubkey || !window.nostr) {
      alert('Please connect with Nostr first');
      return;
    }
    const button = document.getElementById('like-button');
    button.disabled = true;
    try {
      const unsignedEvent = {
        pubkey: userPubkey,
        created_at: Math.floor(Date.now() / 1000),
        kind: 7,
        tags: [['p', authorNpub], ['e', postId], ['type', 'likes']],
        content: 'like'
      };
      const signedEvent = await window.nostr.signEvent(unsignedEvent);
      if (!signedEvent || !signedEvent.sig) throw new Error('Signing cancelled or failed');
      const response = await fetch(apiBase + '/' + encodeURIComponent(postId) + '/like', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(signedEvent)
      });
      const result = await response.json();
      if (result.success) { isLiked = result.liked; updateUI(result.like_count); }
      else if (result.error) { console.error('API error:', result.error); }
    } catch (e) { console.error('Error toggling like:', e); }
    finally { button.disabled = false; }
  };

  function updateUI(count) {
    const button = document.getElementById('like-button');
    const icon = document.getElementById('like-icon');
    const countEl = document.getElementById('like-count');
    button.classList.toggle('liked', isLiked);
    icon.textContent = isLiked ? '\u2665' : '\u2661';
    countEl.textContent = count > 0 ? count + ' like' + (count !== 1 ? 's' : '') : '';
  }

  document.addEventListener('DOMContentLoaded', init);
})();
</script>''';
  }

  /// Build HTML card for a single alert
  static String buildAlertCard(Map<String, dynamic> alert) {
    final severity = alert['severity'] as String;
    final title = escapeHtml(alert['title'] as String);
    final type = escapeHtml(alert['type'] as String);
    final created = alert['created'] as String;
    final author = escapeHtml(alert['author'] as String? ?? alert['callsign'] as String);
    final description = escapeHtml(alert['description'] as String);
    final address = alert['address'] as String?;
    final lat = alert['latitude'] as double;
    final lon = alert['longitude'] as double;

    final addressHtml = address != null && address.isNotEmpty
        ? '<span>\u{1F4CD} ${escapeHtml(address)}</span>'
        : '<span>\u{1F4CD} ${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}</span>';

    return '''
    <div class="alert-card $severity">
      <div class="alert-header">
        <div class="alert-title">$title</div>
        <div class="alert-badges">
          <span class="badge $severity">$severity</span>
          <span class="badge type">$type</span>
        </div>
      </div>
      <div class="alert-meta">
        <span>\u{1F464} $author</span>
        <span>\u{1F550} $created</span>
        $addressHtml
      </div>
      <div class="alert-description">$description</div>
    </div>''';
  }

  /// Build complete alerts page HTML with self-contained dark theme
  static String buildAlertsPage({
    required String stationName,
    required List<Map<String, dynamic>> alerts,
  }) {
    final alertsHtml = alerts.isEmpty
        ? '<p class="no-alerts">No active alerts at this time.</p>'
        : alerts.map((alert) => buildAlertCard(alert)).join('\n');

    return '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Active Alerts - ${escapeHtml(stationName)}</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #1a1a2e; color: #eee; line-height: 1.6; min-height: 100vh; }
    header { background: linear-gradient(135deg, #16213e 0%, #1a1a2e 100%); padding: 20px; border-bottom: 1px solid #333; }
    header h1 { font-size: 1.5rem; color: #fff; }
    header p { color: #888; font-size: 0.9rem; }
    main { max-width: 900px; margin: 0 auto; padding: 20px; }
    .alert-card { background: #16213e; border-radius: 12px; padding: 20px; margin-bottom: 16px; border-left: 4px solid #666; transition: transform 0.2s; }
    .alert-card:hover { transform: translateX(4px); }
    .alert-card.emergency { border-left-color: #e74c3c; background: linear-gradient(90deg, rgba(231,76,60,0.1) 0%, #16213e 30%); }
    .alert-card.urgent { border-left-color: #e67e22; background: linear-gradient(90deg, rgba(230,126,34,0.1) 0%, #16213e 30%); }
    .alert-card.attention { border-left-color: #f1c40f; background: linear-gradient(90deg, rgba(241,196,15,0.1) 0%, #16213e 30%); }
    .alert-card.info { border-left-color: #3498db; background: linear-gradient(90deg, rgba(52,152,219,0.1) 0%, #16213e 30%); }
    .alert-header { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 12px; }
    .alert-title { font-size: 1.2rem; font-weight: 600; color: #fff; }
    .alert-badges { display: flex; gap: 8px; flex-wrap: wrap; }
    .badge { padding: 4px 10px; border-radius: 20px; font-size: 0.75rem; font-weight: 600; text-transform: uppercase; }
    .badge.emergency { background: #e74c3c; color: #fff; }
    .badge.urgent { background: #e67e22; color: #fff; }
    .badge.attention { background: #f1c40f; color: #000; }
    .badge.info { background: #3498db; color: #fff; }
    .badge.type { background: #444; color: #ccc; }
    .alert-meta { display: flex; gap: 16px; flex-wrap: wrap; font-size: 0.85rem; color: #888; margin-bottom: 12px; }
    .alert-meta span { display: flex; align-items: center; gap: 4px; }
    .alert-description { color: #ccc; font-size: 0.95rem; }
    .no-alerts { text-align: center; color: #666; padding: 60px 20px; font-size: 1.1rem; }
    .footer { text-align: center; padding: 30px; color: #555; font-size: 0.85rem; }
    .footer a { color: #3498db; text-decoration: none; }
    @media (max-width: 600px) {
      .alert-header { flex-direction: column; gap: 10px; }
      .alert-meta { flex-direction: column; gap: 8px; }
    }
  </style>
</head>
<body>
  <header>
    <h1>\u{1F6A8} Active Alerts</h1>
    <p>${escapeHtml(stationName)} \u2022 ${alerts.length} active alert${alerts.length == 1 ? '' : 's'}</p>
  </header>
  <main>
    $alertsHtml
  </main>
  <footer class="footer">
    Powered by <a href="https://geogram.radio">Geogram</a>
  </footer>
</body>
</html>''';
  }

  /// Build blog post page HTML with Terminimal theme.
  ///
  /// Unified builder for all blog post contexts (station, device, sync).
  /// Pass [globalStyles] and [appStyles] from theme CSS files.
  /// NOSTR likes are shown when [postId] is provided.
  static String buildBlogPostPage({
    required String postTitle,
    required String postDate,
    String postTime = '',
    required String author,
    required String htmlContent,
    String? description,
    List<String> tags = const [],
    String menuItems = '',
    String logoText = '',
    String logoHref = '../',
    String? postId,
    String? npub,
    int likesCount = 0,
    List<String> likedHexPubkeys = const [],
    bool showSignedBadge = false,
    String commentsHtml = '',
    String globalStyles = '',
    String appStyles = '',
    String? backUrl,
    String backLabel = '\u2190 Back to blog',
  }) {
    final logo = logoText.isNotEmpty ? logoText : author;
    final dateStr = postTime.isNotEmpty ? '$postDate $postTime' : postDate;

    final tagsHtml = tags.isNotEmpty
        ? '<span class="post-tags-inline">:: tags:&nbsp;${tags.map((t) => '<a class="post-tag" href="#">#${escapeHtml(t)}</a>&nbsp;').join('')}</span>'
        : '';

    final descHtml = (description != null && description.isNotEmpty)
        ? '<p style="opacity:0.7;font-style:italic;margin-bottom:20px">${escapeHtml(description)}</p>'
        : '';

    final signedHtml = showSignedBadge
        ? '<div style="color:#4ade80;font-size:0.9rem;margin-top:15px;display:flex;align-items:center;gap:4px"><span>\u2713</span> Signed with NOSTR</div>'
        : '';

    final likesHtml = postId != null ? '''
      <div class="feedback-section" id="feedback-section" style="display: none;">
        <button class="like-button" id="like-button" onclick="toggleLike()">
          <span id="like-icon">\u2661</span>
          <span>Like</span>
        </button>
        <span class="like-count" id="like-count">${likesCount > 0 ? "$likesCount like${likesCount != 1 ? "s" : ""}" : ""}</span>
      </div>''' : '';

    final backHtml = backUrl != null ? '''
      <div class="pagination">
        <div class="pagination__buttons">
          <span class="button"><a href="$backUrl">$backLabel</a></span>
        </div>
      </div>''' : '';

    final nostrScript = postId != null
        ? getNostrLikesScript(
            postId: postId,
            authorNpub: npub ?? '',
            likesCount: likesCount,
            likedHexPubkeys: likedHexPubkeys,
          )
        : '';

    final nostrHeaderHtml = getNostrLoginHeaderHtml();

    final headerHtml = '''
  <header class="header">
    <div class="header__inner">
      <div class="header__logo">
        <a href="$logoHref" style="text-decoration: none;">
          <div class="logo">${escapeHtml(logo)}</div>
        </a>
      </div>
      $nostrHeaderHtml
    </div>
    ${menuItems.isNotEmpty ? '<nav class="menu"><ul class="menu__inner">$menuItems</ul></nav>' : ''}
  </header>''';

    final nostrStyles = getNostrLoginStyles();
    final nostrScripts = getNostrLoginScripts();

    return '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
  <title>${escapeHtml(postTitle)} - ${escapeHtml(author)}</title>
  $nostrStyles
  <style>$globalStyles</style>
  ${appStyles.isNotEmpty ? '<style>$appStyles</style>' : ''}
</head>
<body>
<div class="container">
$headerHtml
  <div class="content">
    <div class="post">
      <h1 class="post-title"><a href="#">${escapeHtml(postTitle)}</a></h1>
      <div class="post-meta-inline">
        <span class="post-date">$dateStr</span>
      </div>
      $tagsHtml
      $descHtml
      <div class="post-content">
        $htmlContent
      </div>
      $commentsHtml
      $signedHtml
      $likesHtml
      $backHtml
    </div>
  </div>
  <footer class="footer">
    <div class="footer__inner">
      <div class="copyright">
        <span>published via geogram</span>
      </div>
    </div>
  </footer>
</div>
$nostrScript
<script>$nostrScripts</script>
</body>
</html>''';
  }

  /// CSS for station homepage elements not covered by theme CSS
  /// (search, map/Leaflet, toast, device marker icons, marker clusters)
  static String getStationHomepageExtraStyles({
    String mapDisplay = 'none',
    String devicesDisplay = 'none',
    String noDevicesDisplay = 'block',
  }) {
    return '''
/* Station Info */
.station-info { margin-bottom: 40px; }
.info-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
  gap: 15px;
}
.info-item {
  background: var(--accent-alpha-20);
  padding: 15px;
  border-radius: 8px;
  text-align: center;
}
.info-label {
  display: block;
  font-size: 0.75rem;
  color: var(--accent-alpha-70);
  margin-bottom: 5px;
  text-transform: uppercase;
  letter-spacing: 0.5px;
}
.info-value {
  display: block;
  font-size: 1.1rem;
  font-weight: bold;
}
.status-online { color: #4ade80; }
/* Devices Section */
.devices-section { margin-bottom: 40px; }
.devices-grid {
  display: $devicesDisplay;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: 20px;
}
.device-card {
  display: block;
  background: var(--background);
  border: 1px solid var(--border-color);
  border-radius: 8px;
  padding: 20px;
  text-decoration: none;
  transition: border-color 0.2s ease, box-shadow 0.2s ease;
}
.device-card:hover {
  border-color: var(--accent);
  box-shadow: var(--shadow);
}
.device-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 10px;
}
.device-callsign {
  font-size: 1.1rem;
  font-weight: bold;
  color: var(--accent);
}
.connection-badge {
  font-size: 0.7rem;
  padding: 3px 8px;
  border-radius: 4px;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  background: var(--accent-alpha-20);
  color: var(--accent);
}
.connection-badge.localWifi { background: rgba(74, 222, 128, 0.2); color: #4ade80; }
.connection-badge.internet { background: rgba(96, 165, 250, 0.2); color: #60a5fa; }
.connection-badge.bluetooth { background: rgba(167, 139, 250, 0.2); color: #a78bfa; }
.connection-badge.lora, .connection-badge.radio { background: rgba(251, 191, 36, 0.2); color: #fbbf24; }
.device-nickname { font-size: 1rem; margin-bottom: 8px; }
.device-meta { font-size: 0.85rem; color: var(--accent-alpha-70); }
.no-devices {
  display: $noDevicesDisplay;
  text-align: center;
  padding: 40px 20px;
  background: var(--accent-alpha-20);
  border-radius: 8px;
}
.no-devices p { margin: 0 0 10px 0; }
.no-devices .hint { font-size: 0.9rem; color: var(--accent-alpha-70); margin: 0; }
/* API Section */
.api-section { margin-bottom: 40px; }
.api-list { display: flex; flex-direction: column; gap: 10px; }
.api-link {
  display: flex;
  align-items: center;
  gap: 15px;
  padding: 12px 15px;
  background: var(--accent-alpha-20);
  border-radius: 6px;
  text-decoration: none;
  transition: background 0.2s ease;
}
.api-link:hover { background: var(--accent-alpha-70); }
.api-method {
  font-size: 0.75rem;
  font-weight: bold;
  padding: 2px 8px;
  background: var(--accent);
  color: var(--background);
  border-radius: 4px;
}
.api-path { font-family: monospace; font-weight: bold; }
.api-desc { color: var(--accent-alpha-70); margin-left: auto; font-size: 0.9rem; }
/* Search Section */
.search-section { margin-bottom: 50px; }
.search-box { display: flex; align-items: stretch; }
.search-input {
  flex: 1; padding: 16px 20px; font-size: 1.1rem;
  border: 2px solid var(--accent); border-right: none;
  border-radius: 8px 0 0 8px;
  background: var(--background); color: var(--color);
  outline: none; transition: box-shadow 0.2s ease;
}
.search-input:hover, .search-input:focus { box-shadow: 0 0 0 3px var(--accent-alpha-20); }
.search-input::placeholder { color: var(--accent-alpha-70); }
.search-btn {
  padding: 16px 20px; background: var(--accent);
  border: 2px solid var(--accent); border-radius: 0 8px 8px 0;
  cursor: pointer; display: flex; align-items: center; justify-content: center;
  transition: background 0.2s ease;
}
.search-btn:hover { background: var(--accent-alpha-70); }
.search-btn svg { width: 24px; height: 24px; fill: #000; }
/* Toast */
.toast {
  position: fixed; bottom: 20px; left: 50%;
  transform: translateX(-50%) translateY(100px);
  background: var(--accent); color: #000;
  padding: 12px 24px; border-radius: 8px; font-weight: bold;
  opacity: 0; transition: transform 0.3s ease, opacity 0.3s ease;
  z-index: 9999;
}
.toast.show { transform: translateX(-50%) translateY(0); opacity: 1; }
/* Section header for station layout */
.section-header {
  display: flex; align-items: center; justify-content: space-between;
  padding-bottom: 15px; border-bottom: 1px solid var(--border-color);
  margin-bottom: 20px;
}
.section-header h2 { margin: 0; }
/* Map Section */
.map-section { display: $mapDisplay; margin-bottom: 30px; }
.map-container {
  position: relative; width: 100%; height: 160px;
  border-radius: 8px; overflow: hidden;
  border: 1px solid var(--border-color);
}
#devices-map { width: 100%; height: 100%; }
.fullscreen-btn {
  position: absolute; top: 10px; right: 10px; z-index: 1000;
  background: rgba(0,0,0,0.6); border: none; border-radius: 4px;
  padding: 6px 8px; cursor: pointer; color: #fff;
  display: flex; align-items: center; justify-content: center;
  transition: background 0.2s ease;
}
.fullscreen-btn:hover { background: rgba(0,0,0,0.8); }
.fullscreen-btn svg { width: 16px; height: 16px; fill: currentColor; }
/* Fullscreen map modal */
.map-modal {
  display: none; position: fixed; top: 0; left: 0;
  width: 100vw; height: 100vh; background: #000; z-index: 10000;
}
.map-modal.active { display: block; }
.map-modal .close-btn {
  position: absolute; top: 20px; right: 20px; z-index: 10001;
  background: rgba(0,0,0,0.7); border: none; border-radius: 8px;
  padding: 12px 16px; cursor: pointer; color: #fff;
  font-family: inherit; font-size: 0.9rem;
  display: flex; align-items: center; gap: 8px;
  transition: background 0.2s ease;
}
.map-modal .close-btn:hover { background: rgba(0,0,0,0.9); }
.map-modal .close-btn svg { width: 16px; height: 16px; fill: currentColor; }
#fullscreen-map { width: 100%; height: 100%; }
/* Leaflet customization */
.leaflet-popup-content-wrapper { background: var(--background); color: var(--color); border-radius: 8px; font-family: inherit; }
.leaflet-popup-tip { background: var(--background); }
.leaflet-container { font-family: inherit; background: #1a1a2e; }
.leaflet-tile-container img { outline: 1px solid transparent; }
.leaflet-tile { filter: none; outline: none; }
/* Device marker icons */
.device-icon {
  display: flex; align-items: center; justify-content: center;
  width: 28px; height: 28px;
  background: var(--accent); border: 2px solid #fff;
  border-radius: 50%; box-shadow: 0 2px 6px rgba(0,0,0,0.4);
}
.device-icon svg { width: 14px; height: 14px; fill: #000; }
/* Marker clusters */
.marker-cluster { background: rgba(255,168,106,0.4); }
.marker-cluster div { background: var(--accent); color: #000; font-weight: bold; font-family: inherit; }
.marker-cluster-small { background: rgba(255,168,106,0.4); }
.marker-cluster-small div { background: var(--accent); }
.marker-cluster-medium { background: rgba(255,168,106,0.5); }
.marker-cluster-medium div { background: var(--accent); }
.marker-cluster-large { background: rgba(255,168,106,0.6); }
.marker-cluster-large div { background: var(--accent); }

/* Header Navigation - Combined breadcrumb style */
.header-nav {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  font-size: 1.1rem;
  padding: 10px 0;
}
.header-nav .nav-name {
  color: var(--accent);
  text-decoration: none;
  font-weight: bold;
}
.header-nav .nav-name:hover {
  text-decoration: underline;
}
.header-nav .nav-separator {
  color: var(--accent-alpha-70);
  margin: 0 2px;
}
.header-nav .nav-pipe {
  color: var(--accent-alpha-70);
}
.header-nav .nav-item {
  color: var(--color);
  text-decoration: none;
}
.header-nav .nav-item:hover {
  color: var(--accent);
}
.header-nav .nav-item.active {
  color: var(--accent-alpha-70);
}
''';
  }

  /// Station homepage JavaScript for map, dynamic updates, search toast
  static String getStationHomepageScript(String devicesJson) {
    return '''
    let searchToastShown = false;
    function showSearchToast() {
      if (searchToastShown) return;
      searchToastShown = true;
      const toast = document.getElementById('toast');
      toast.classList.add('show');
      setTimeout(() => toast.classList.remove('show'), 2500);
    }

    const devices = [$devicesJson];
    let mainMap = null;
    let fullscreenMap = null;

    const phoneIcon = '<svg viewBox="0 0 24 24"><path d="M17 1.01L7 1c-1.1 0-2 .9-2 2v18c0 1.1.9 2 2 2h10c1.1 0 2-.9 2-2V3c0-1.1-.9-1.99-2-1.99zM17 19H7V5h10v14z"/></svg>';
    const laptopIcon = '<svg viewBox="0 0 24 24"><path d="M20 18c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2H4c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2H0v2h24v-2h-4zM4 6h16v10H4V6z"/></svg>';

    function createMarker(device) {
      const iconSvg = device.icon === 'phone' ? phoneIcon : laptopIcon;
      const icon = L.divIcon({
        className: '',
        html: '<div class="device-icon">' + iconSvg + '</div>',
        iconSize: [28, 28], iconAnchor: [14, 14], popupAnchor: [0, -14]
      });
      const marker = L.marker([device.lat, device.lng], { icon: icon });
      let popupContent = '<a href="/' + device.callsign + '/" style="font-weight:bold;color:var(--accent)">' + device.callsign + '</a>';
      if (device.nickname && device.nickname !== device.callsign) {
        popupContent += '<br>' + device.nickname;
      }
      marker.bindPopup(popupContent);
      return marker;
    }

    function initMap(mapId, isFullscreen) {
      const map = L.map(mapId, {
        zoomControl: isFullscreen, attributionControl: false,
        worldCopyJump: false, maxBounds: [[-90, -180], [90, 180]], maxBoundsViscosity: 1.0
      });
      L.tileLayer('/tiles/sat/{z}/{x}/{y}.png?layer=satellite', { maxZoom: 18, minZoom: 2, bounds: [[-90, -180], [90, 180]] }).addTo(map);
      L.tileLayer('/tiles/labels/{z}/{x}/{y}.png?layer=labels', { maxZoom: 18, minZoom: 2, bounds: [[-90, -180], [90, 180]] }).addTo(map);
      const markers = L.markerClusterGroup({ maxClusterRadius: 50, spiderfyOnMaxZoom: true, showCoverageOnHover: false, zoomToBoundsOnClick: true });
      devices.forEach(function(device) { markers.addLayer(createMarker(device)); });
      map.addLayer(markers);
      map.setView([40, -20], 2);
      return map;
    }

    function openFullscreenMap() {
      document.getElementById('map-modal').classList.add('active');
      document.body.style.overflow = 'hidden';
      if (!fullscreenMap) { fullscreenMap = initMap('fullscreen-map', true); }
      else { fullscreenMap.invalidateSize(); }
    }

    function closeFullscreenMap() {
      document.getElementById('map-modal').classList.remove('active');
      document.body.style.overflow = '';
    }

    document.addEventListener('keydown', function(e) { if (e.key === 'Escape') closeFullscreenMap(); });

    document.addEventListener('DOMContentLoaded', function() {
      if (devices.length > 0) { mainMap = initMap('devices-map', false); }
    });

    let mainMarkers = null;
    let fullscreenMarkers = null;

    function formatUptime(minutes) {
      if (minutes < 1) return '0 minutes';
      const days = Math.floor(minutes / 1440);
      const hours = Math.floor((minutes % 1440) / 60);
      const mins = minutes % 60;
      const parts = [];
      if (days > 0) parts.push(days + (days === 1 ? ' day' : ' days'));
      if (hours > 0) parts.push(hours + (hours === 1 ? ' hour' : ' hours'));
      if (mins > 0 && days === 0) parts.push(mins + (mins === 1 ? ' minute' : ' minutes'));
      return parts.length === 0 ? '0 minutes' : parts.join(' ');
    }

    function formatTimeAgo(isoString) {
      const then = new Date(isoString);
      const now = new Date();
      const diff = Math.floor((now - then) / 1000);
      if (diff >= 2592000) { const m = Math.floor(diff / 2592000); return m + (m === 1 ? ' month' : ' months') + ' ago'; }
      if (diff >= 604800) { const w = Math.floor(diff / 604800); return w + (w === 1 ? ' week' : ' weeks') + ' ago'; }
      if (diff >= 86400) { const d = Math.floor(diff / 86400); return d + (d === 1 ? ' day' : ' days') + ' ago'; }
      if (diff >= 3600) { const h = Math.floor(diff / 3600); return h + (h === 1 ? ' hour' : ' hours') + ' ago'; }
      if (diff >= 60) { const m = Math.floor(diff / 60); return m + (m === 1 ? ' minute' : ' minutes') + ' ago'; }
      return 'just now';
    }

    function escapeHtml(text) {
      const div = document.createElement('div');
      div.textContent = text || '';
      return div.innerHTML;
    }

    function getDeviceIcon(platform, deviceType) {
      const p = (platform || '').toLowerCase();
      const d = (deviceType || '').toLowerCase();
      if (p.includes('android') || p.includes('ios') || d.includes('phone') || d.includes('mobile')) return 'phone';
      if (p.includes('linux') || p.includes('windows') || p.includes('mac') || d.includes('desktop') || d.includes('computer')) return 'desktop';
      if (d.includes('station')) return 'station';
      return 'phone';
    }

    function updateDeviceCards(clients) {
      const grid = document.querySelector('.devices-grid');
      const emptyState = document.querySelector('.no-devices');
      if (!grid || !emptyState) return;
      if (clients.length === 0) { grid.style.display = 'none'; emptyState.style.display = 'block'; return; }
      grid.style.display = 'grid'; emptyState.style.display = 'none';
      grid.innerHTML = clients.map(c => {
        const callsign = c.callsign || 'Unknown';
        const nickname = c.nickname || callsign;
        const nicknameHtml = nickname !== callsign ? '<div class="device-nickname">' + escapeHtml(nickname) + '</div>' : '';
        const location = (c.latitude && c.longitude) ? ' \\u00b7 ' + c.latitude.toFixed(2) + ', ' + c.longitude.toFixed(2) : '';
        return '<a href="/' + callsign + '/" class="device-card"><div class="device-header"><span class="device-callsign">' + escapeHtml(callsign) + '</span><span class="connection-badge internet">Internet</span></div>' + nicknameHtml + '<div class="device-meta">Connected since ' + formatTimeAgo(c.connected_at) + location + '</div></a>';
      }).join('');
    }

    function updateMapMarkers(clients, map, existingMarkers) {
      if (!map) return null;
      if (existingMarkers) map.removeLayer(existingMarkers);
      const withLocation = clients.filter(c => c.latitude && c.longitude);
      if (withLocation.length === 0) return null;
      const markers = L.markerClusterGroup({ maxClusterRadius: 50, spiderfyOnMaxZoom: true, showCoverageOnHover: false, zoomToBoundsOnClick: true });
      withLocation.forEach(function(c) {
        markers.addLayer(createMarker({ callsign: c.callsign || 'Unknown', nickname: c.nickname || c.callsign || 'Unknown', lat: c.latitude, lng: c.longitude, icon: getDeviceIcon(c.platform, c.device_type) }));
      });
      map.addLayer(markers);
      return markers;
    }

    setInterval(async function() {
      try {
        const [clientsResponse, statusResponse] = await Promise.all([fetch('/api/clients'), fetch('/api/status')]);
        const clientsData = await clientsResponse.json();
        const statusData = await statusResponse.json();
        const clients = clientsData.clients || [];
        updateDeviceCards(clients);
        const uptimeEl = document.getElementById('uptime-value');
        if (uptimeEl && typeof statusData.uptime === 'number') uptimeEl.textContent = formatUptime(statusData.uptime);
        const connectedEl = document.getElementById('connected-count');
        if (connectedEl && typeof statusData.connected_devices === 'number') {
          const count = statusData.connected_devices;
          connectedEl.textContent = count + (count === 1 ? ' device' : ' devices');
        }
        mainMarkers = updateMapMarkers(clients, mainMap, mainMarkers);
        fullscreenMarkers = updateMapMarkers(clients, fullscreenMap, fullscreenMarkers);
        if (!mainMap && clients.some(c => c.latitude && c.longitude)) {
          mainMap = initMap('devices-map', false);
          mainMarkers = updateMapMarkers(clients, mainMap, null);
        }
      } catch (e) { console.error('Failed to refresh:', e); }
    }, 10000);
''';
  }

  /// Build complete station homepage HTML
  static String buildStationHomepage({
    required String stationName,
    required String callsign,
    required String version,
    required String uptimeStr,
    required int clientCount,
    required String devicesHtml,
    required String devicesJson,
    required String menuItems,
    required bool hasDevicesWithLocation,
    String globalStyles = '',
    String stationStyles = '',
  }) {
    final mapDisplay = hasDevicesWithLocation ? 'block' : 'none';
    final devicesDisplay = clientCount > 0 ? 'grid' : 'none';
    final noDevicesDisplay = clientCount > 0 ? 'none' : 'block';
    final extraStyles = getStationHomepageExtraStyles(
      mapDisplay: mapDisplay,
      devicesDisplay: devicesDisplay,
      noDevicesDisplay: noDevicesDisplay,
    );

    return '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${escapeHtml(stationName)} - geogram Station</title>
  <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
  <link rel="stylesheet" href="https://unpkg.com/leaflet.markercluster@1.4.1/dist/MarkerCluster.css" />
  <link rel="stylesheet" href="https://unpkg.com/leaflet.markercluster@1.4.1/dist/MarkerCluster.Default.css" />
  <style>
$globalStyles
$stationStyles
$extraStyles
  </style>
</head>
<body>
  <div class="container">
    <header class="header">
      <div class="header__inner">
        <div class="header__logo">
          <a href="/" style="text-decoration: none;">
            <div class="logo">${escapeHtml(stationName)}</div>
          </a>
        </div>
      </div>
      <nav class="menu">
        <ul class="menu__inner">
          $menuItems
        </ul>
      </nav>
    </header>

    <main class="main">
      <section class="search-section">
        <div class="search-box">
          <input type="text" id="search-input" class="search-input" placeholder="Search..." onclick="showSearchToast()" readonly>
          <button class="search-btn" onclick="showSearchToast()">
            <svg viewBox="0 0 24 24"><path d="M15.5 14h-.79l-.28-.27A6.471 6.471 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z"/></svg>
          </button>
        </div>
      </section>

      <section class="devices-section">
        <div class="section-header">
          <h2>Connected Devices</h2>
        </div>

        <section class="map-section">
          <div class="map-container">
            <div id="devices-map"></div>
            <button class="fullscreen-btn" onclick="openFullscreenMap()" title="Fullscreen">
              <svg viewBox="0 0 24 24"><path d="M7 14H5v5h5v-2H7v-3zm-2-4h2V7h3V5H5v5zm12 7h-3v2h5v-5h-2v3zM14 5v2h3v3h2V5h-5z"/></svg>
            </button>
          </div>
        </section>

        <section class="station-info">
          <div class="info-grid">
            <div class="info-item">
              <span class="info-label">Version</span>
              <span class="info-value">$version</span>
            </div>
            <div class="info-item">
              <span class="info-label">Callsign</span>
              <span class="info-value">${escapeHtml(callsign)}</span>
            </div>
            <div class="info-item">
              <span class="info-label">Connected</span>
              <span class="info-value" id="connected-count">$clientCount ${clientCount == 1 ? 'device' : 'devices'}</span>
            </div>
            <div class="info-item">
              <span class="info-label">Uptime</span>
              <span class="info-value" id="uptime-value">$uptimeStr</span>
            </div>
            <div class="info-item">
              <span class="info-label">Status</span>
              <span class="info-value status-online">Running</span>
            </div>
          </div>
        </section>

        <div class="devices-grid">
          $devicesHtml
        </div>
        <div class="no-devices">
          <p>No devices currently connected.</p>
          <p class="hint">Devices will appear here when they connect to this station.</p>
        </div>
      </section>

      <section class="api-section">
        <div class="section-header">
          <h2>API Endpoints</h2>
        </div>
        <div class="api-list">
          <a href="/api/status" class="api-link">
            <span class="api-method">GET</span>
            <span class="api-path">/api/status</span>
            <span class="api-desc">Station status and info</span>
          </a>
          <a href="/api/clients" class="api-link">
            <span class="api-method">GET</span>
            <span class="api-path">/api/clients</span>
            <span class="api-desc">Connected devices list</span>
          </a>
        </div>
      </section>
    </main>

    <footer class="footer">
      <div class="footer__inner">
        <div class="copyright">
          <span>published via geogram</span>
        </div>
      </div>
    </footer>
  </div>

  <div class="map-modal" id="map-modal">
    <button class="close-btn" onclick="closeFullscreenMap()">
      <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
      <span>Close</span>
    </button>
    <div id="fullscreen-map"></div>
  </div>

  <div id="toast" class="toast">Coming soon</div>

  <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
  <script src="https://unpkg.com/leaflet.markercluster@1.4.1/dist/leaflet.markercluster.js"></script>
  <script>
${getStationHomepageScript(devicesJson)}
  </script>
</body>
</html>''';
  }

}
