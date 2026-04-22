/// Embedded theme files for CLI distribution
/// These themes are bundled with the CLI binary and extracted on startup
///
/// AUTO-GENERATED FILE - DO NOT EDIT MANUALLY
/// Run: dart bin/generate_embedded_themes.dart

class ThemesEmbedded {
  /// Map of relative path (under themes/) to file content
  static const Map<String, String> files = {
    'default/alerts/index.html': _defaultAlertsIndexHtml,
    'default/alerts/styles.css': _defaultAlertsStylesCss,
    'default/blog/index.html': _defaultBlogIndexHtml,
    'default/blog/post.html': _defaultBlogPostHtml,
    'default/blog/styles.css': _defaultBlogStylesCss,
    'default/chat/index.html': _defaultChatIndexHtml,
    'default/chat/styles.css': _defaultChatStylesCss,
    'default/events/event.html': _defaultEventsEventHtml,
    'default/events/index.html': _defaultEventsIndexHtml,
    'default/events/styles.css': _defaultEventsStylesCss,
    'default/files/index.html': _defaultFilesIndexHtml,
    'default/files/styles.css': _defaultFilesStylesCss,
    'default/forum/index.html': _defaultForumIndexHtml,
    'default/forum/styles.css': _defaultForumStylesCss,
    'default/home/index.html': _defaultHomeIndexHtml,
    'default/home/styles.css': _defaultHomeStylesCss,
    'default/meet/index.html': _defaultMeetIndexHtml,
    'default/meet/listing.html': _defaultMeetListingHtml,
    'default/meet/styles.css': _defaultMeetStylesCss,
    'default/shared/directory.html': _defaultSharedDirectoryHtml,
    'default/shared/index.html': _defaultSharedIndexHtml,
    'default/shared/styles.css': _defaultSharedStylesCss,
    'default/station/index.html': _defaultStationIndexHtml,
    'default/station/styles.css': _defaultStationStylesCss,
    'default/styles.css': _defaultStylesCss,
    'default/www/index.html': _defaultWwwIndexHtml,
    'default/www/styles.css': _defaultWwwStylesCss
  };

  static const String _defaultAlertsIndexHtml = r'''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{{TITLE}} - Alerts</title>
  <link rel="stylesheet" href="/styles.css">
  <link rel="stylesheet" href="styles.css">
</head>
<body>
  <header class="header">
    <div class="container">
      <div class="header-content">
        <div>
          <h1 class="header-title">{{COLLECTION_NAME}}</h1>
          <p class="header-subtitle">{{COLLECTION_DESCRIPTION}}</p>
        </div>
        <nav class="nav">
          <span class="badge badge-warning">Alerts</span>
        </nav>
      </div>
    </div>
  </header>

  <main class="main">
    <div class="container">
      <div class="alerts-header">
        <div class="search-container">
          <input type="text" class="input search-input" placeholder="Search alerts..." id="search">
        </div>
        <div class="filter-buttons">
          <button class="btn btn-secondary active" data-filter="all">All</button>
          <button class="btn btn-secondary" data-filter="critical">Critical</button>
          <button class="btn btn-secondary" data-filter="warning">Warning</button>
          <button class="btn btn-secondary" data-filter="info">Info</button>
        </div>
      </div>

      <div class="alerts-list" id="alerts">
        {{CONTENT}}
      </div>
    </div>
  </main>

  <footer class="footer">
    <div class="container">
      <p>Generated on {{GENERATED_DATE}}</p>
    </div>
  </footer>

  <script>
    window.GEOGRAM_DATA = {{DATA_JSON}};
    {{SCRIPTS}}
  </script>
  <script>
    // Search functionality
    document.getElementById('search').addEventListener('input', function(e) {
      const query = e.target.value.toLowerCase();
      const alerts = document.querySelectorAll('.alert-item');
      alerts.forEach(alert => {
        const text = alert.textContent.toLowerCase();
        alert.style.display = text.includes(query) ? '' : 'none';
      });
    });

    // Filter functionality
    document.querySelectorAll('.filter-buttons .btn').forEach(btn => {
      btn.addEventListener('click', function() {
        document.querySelectorAll('.filter-buttons .btn').forEach(b => b.classList.remove('active'));
        this.classList.add('active');
        const filter = this.dataset.filter;
        const alerts = document.querySelectorAll('.alert-item');
        alerts.forEach(alert => {
          if (filter === 'all') {
            alert.style.display = '';
          } else {
            alert.style.display = alert.classList.contains(filter) ? '' : 'none';
          }
        });
      });
    });
  </script>
</body>
</html>
''';

  static const String _defaultAlertsStylesCss = r'''
/* Alerts App - Theme Overrides */

/* Alerts Header */
.alerts-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: var(--spacing-lg);
  gap: var(--spacing-md);
}

@media (max-width: 768px) {
  .alerts-header {
    flex-direction: column;
    align-items: stretch;
  }
}

.filter-buttons {
  display: flex;
  gap: var(--spacing-xs);
  flex-wrap: wrap;
}

.filter-buttons .btn.active {
  background-color: var(--color-accent);
  color: white;
}

/* Alerts List */
.alerts-list {
  display: flex;
  flex-direction: column;
  gap: var(--spacing-md);
}

/* Alert Item */
.alert-item {
  display: flex;
  gap: var(--spacing-md);
  padding: var(--spacing-lg);
  background-color: var(--color-bg);
  border: 1px solid var(--color-border-light);
  border-radius: var(--border-radius);
  border-left: 4px solid var(--color-border);
  transition: box-shadow var(--transition-fast);
}

.alert-item:hover {
  box-shadow: var(--shadow-md);
}

/* Alert Severity Levels */
.alert-item.critical {
  border-left-color: var(--color-error);
  background-color: rgba(255, 59, 48, 0.05);
}

.alert-item.warning {
  border-left-color: var(--color-warning);
  background-color: rgba(255, 149, 0, 0.05);
}

.alert-item.info {
  border-left-color: var(--color-accent);
  background-color: rgba(0, 102, 204, 0.05);
}

.alert-item.success {
  border-left-color: var(--color-success);
  background-color: rgba(52, 199, 89, 0.05);
}

/* Alert Icon */
.alert-icon {
  flex-shrink: 0;
  width: 40px;
  height: 40px;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 50%;
  font-size: var(--font-size-xl);
}

.alert-item.critical .alert-icon {
  background-color: var(--color-error);
  color: white;
}

.alert-item.warning .alert-icon {
  background-color: var(--color-warning);
  color: white;
}

.alert-item.info .alert-icon {
  background-color: var(--color-accent);
  color: white;
}

.alert-item.success .alert-icon {
  background-color: var(--color-success);
  color: white;
}

/* Alert Content */
.alert-content {
  flex: 1;
  min-width: 0;
}

.alert-header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: var(--spacing-md);
  margin-bottom: var(--spacing-sm);
}

.alert-title {
  font-size: var(--font-size-lg);
  font-weight: 600;
  color: var(--color-text);
  margin: 0;
}

.alert-time {
  font-size: var(--font-size-sm);
  color: var(--color-text-muted);
  white-space: nowrap;
}

.alert-message {
  color: var(--color-text-secondary);
  margin-bottom: var(--spacing-md);
}

.alert-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--spacing-md);
}

/* Alert Source */
.alert-source {
  font-size: var(--font-size-sm);
  color: var(--color-text-muted);
  display: flex;
  align-items: center;
  gap: var(--spacing-xs);
}

/* Alert Tags */
.alert-tags {
  display: flex;
  flex-wrap: wrap;
  gap: var(--spacing-xs);
}

.alert-tag {
  font-size: var(--font-size-xs);
  padding: var(--spacing-xs) var(--spacing-sm);
  background-color: var(--color-bg-secondary);
  border-radius: var(--border-radius-sm);
  color: var(--color-text-secondary);
}

/* Alert Actions */
.alert-actions {
  display: flex;
  gap: var(--spacing-sm);
}

/* Unread Alert */
.alert-item.unread {
  background-color: var(--color-bg-secondary);
}

.alert-item.unread .alert-title::before {
  content: '';
  display: inline-block;
  width: 8px;
  height: 8px;
  background-color: var(--color-accent);
  border-radius: 50%;
  margin-right: var(--spacing-sm);
}

/* Acknowledged Alert */
.alert-item.acknowledged {
  opacity: 0.7;
}

.alert-item.acknowledged .alert-title {
  text-decoration: line-through;
}
''';

  static const String _defaultBlogIndexHtml = r'''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
  <title>Blog - {{COLLECTION_NAME}}</title>
  <link rel="stylesheet" href="/styles.css">
  <link rel="stylesheet" href="styles.css">
</head>
<body>
<div class="container">
  <header class="header">
    <div class="header__inner">
      <div class="header__logo">
        <a href="../" style="text-decoration: none;">
          <div class="logo">{{COLLECTION_NAME}}</div>
        </a>
      </div>
    </div>
    <nav class="menu">
      <ul class="menu__inner">
        {{MENU_ITEMS}}
      </ul>
    </nav>
  </header>

  <div class="content">
    <div class="posts">
      {{CONTENT}}
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
</body>
</html>
''';

  static const String _defaultBlogPostHtml = r'''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
  <title>{{POST_TITLE}} - {{COLLECTION_NAME}}</title>
  <link rel="stylesheet" href="/styles.css">
  <link rel="stylesheet" href="styles.css">
</head>
<body>
<div class="container">
  <header class="header">
    <div class="header__inner">
      <div class="header__logo">
        <a href="../" style="text-decoration: none;">
          <div class="logo">{{COLLECTION_NAME}}</div>
        </a>
      </div>
    </div>
    <nav class="menu">
      <ul class="menu__inner">
        {{MENU_ITEMS}}
      </ul>
    </nav>
  </header>

  <div class="content">
    <div class="post">
      <h1 class="post-title">{{POST_TITLE}}</h1>
      {{DESCRIPTION}}
      <div class="post-meta-inline">
        <span class="post-date">{{POST_DATE}}</span>
      </div>
      {{TAGS}}

      <div class="post-content">
        {{CONTENT}}
      </div>

      {{COMMENTS}}

      <div class="pagination">
        <div class="pagination__buttons">
          <span class="button">
            <a href="./">← Back to blog</a>
          </span>
        </div>
      </div>
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
</body>
</html>
''';

  static const String _defaultBlogStylesCss = r'''
/* Blog styles - extends global */

/* ── Timeline (shared with events) ──────────────── */

.timeline {
  position: relative;
}

.tl-year-group {
  margin-bottom: 10px;
}

.tl-year-header {
  display: flex;
  align-items: center;
  margin-bottom: 0;
  position: relative;
}

.tl-year-label {
  display: inline-block;
  font-size: 0.85rem;
  font-weight: 700;
  letter-spacing: 0.1em;
  color: var(--accent);
  background: var(--background);
  padding: 4px 12px;
  border: 2px dashed var(--accent);
  position: relative;
  z-index: 1;
}

.tl-track {
  position: relative;
  padding-left: 28px;
  border-left: 2px dashed var(--border-color);
  margin-left: 18px;
}

.tl-node {
  display: block;
  position: relative;
  padding: 16px 0;
  text-decoration: none;
  color: inherit;
}

.tl-node:not(:last-child) {
  border-bottom: 1px solid var(--border-color);
}

.tl-dot {
  position: absolute;
  left: -34px;
  top: 22px;
  width: 10px;
  height: 10px;
  border-radius: 50%;
  background: var(--border-color);
  border: 2px solid var(--background);
  box-shadow: 0 0 0 2px var(--border-color);
  transition: all 0.15s;
}

.tl-node:hover .tl-dot {
  background: var(--accent);
  box-shadow: 0 0 0 2px var(--accent);
}

.tl-card {
  transition: transform 0.1s;
}

.tl-node:hover .tl-card {
  transform: translateX(4px);
}

.tl-title {
  font-size: 1.1rem;
  font-weight: 600;
  color: var(--accent);
  margin-bottom: 4px;
  line-height: 1.3;
}

.tl-desc {
  font-size: 0.9rem;
  color: var(--color);
  opacity: 0.7;
  margin-bottom: 4px;
}

.tl-excerpt {
  font-size: 0.85rem;
  color: var(--color);
  opacity: 0.55;
  margin-bottom: 4px;
  line-height: 1.5;
}

.tl-meta {
  font-size: 0.9rem;
  color: var(--color);
  opacity: 0.6;
}

.tl-sep {
  margin: 0 6px;
  opacity: 0.4;
}

@media (max-width: 480px) {
  .tl-track {
    padding-left: 20px;
    margin-left: 12px;
  }
  .tl-dot {
    left: -26px;
    width: 8px;
    height: 8px;
  }
}

/* ── Blog listing cards ─────────────────────────── */

/* Override global post-title styles for blog cards */
.post.on-list .post-title {
  border-bottom: none;
  padding-bottom: 0;
  margin: 0 0 10px;
  font-size: 1.35rem;
  font-weight: 700;
  line-height: 1.3;
}

/* Remove the > prefix — the card itself is the affordance */
.post.on-list .post-title::before {
  content: none;
}

/* Clickable card link wrapping the entire post */
.blog-card-link,
.blog-card-link:hover,
.blog-card-link:visited {
  display: block;
  text-decoration: none;
  color: inherit;
}

/* Excerpt — the most prominent text after the title */
.blog-excerpt {
  margin: 0 0 12px;
  font-size: 0.95rem;
  line-height: 1.6;
  color: var(--color);
  opacity: 0.75;
}

/* Footer row: date · tags · read more */
.blog-card-footer {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px 14px;
  font-size: 0.85rem;
  color: var(--accent-alpha-70);
}

.blog-card-date {
  font-family: monospace;
}

.blog-card-tags {
  opacity: 0.6;
}

.blog-card-read {
  margin-left: auto;
  color: var(--accent);
  opacity: 0;
  transition: opacity 0.15s;
}

.post.on-list:hover .blog-card-read {
  opacity: 1;
}

/* Tighten spacing between cards */
.post.on-list {
  padding: 16px 12px;
  margin: 0 -12px;
  border-radius: 4px;
}

/* Feedback section — matches events page design */
.feedback-section {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-top: 30px;
  padding-top: 20px;
  border-top: 1px solid var(--border-color);
}

.like-button {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 8px 18px;
  border: 1px solid var(--border-color);
  border-radius: 6px;
  background: transparent;
  color: var(--color);
  cursor: pointer;
  font-size: 1rem;
  font-family: inherit;
  transition: all 0.15s;
}

.like-button svg {
  width: 16px;
  height: 16px;
}

.like-button:hover:not(:disabled) {
  border-color: var(--accent);
  color: var(--accent);
}

.like-button.liked {
  border-color: var(--accent);
  color: var(--accent);
}

.like-button:disabled {
  opacity: 0.4;
  cursor: default;
}

.like-count {
  font-size: 0.9rem;
  color: var(--accent-alpha-70);
}

.like-hint {
  font-size: 0.85rem;
  color: var(--accent-alpha-70);
}

.nostr-notice {
  font-size: 0.85rem;
  color: var(--accent-alpha-70);
}

.nostr-notice a {
  color: var(--accent);
}

/* Blog post detail — title without italic, no link underline */
.post > .post-title {
  font-style: normal;
}
.post > .post-title a {
  pointer-events: none;
  color: inherit;
  text-decoration: none;
}
''';

  static const String _defaultChatIndexHtml = r'''
<!DOCTYPE html>
<html lang="en" class="chat-page">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
  <title>Chat - {{COLLECTION_NAME}}</title>
  <link rel="stylesheet" href="/styles.css">
  <link rel="stylesheet" href="styles.css?v=3">
  {{NOSTR_STYLES}}
</head>
<body>
<div class="container">
  <header class="header">
    <div class="header__inner">
      <div class="header__logo">
        <a href="{{HOME_URL}}" style="text-decoration: none;">
          <div class="logo">{{COLLECTION_NAME}}</div>
        </a>
      </div>
      {{NOSTR_HEADER}}
    </div>
    <nav class="menu">
      <ul class="menu__inner">
        {{MENU_ITEMS}}
      </ul>
    </nav>
  </header>

  <div class="content">
    <div class="chat-layout">
      <!-- Channels sidebar -->
      <aside class="channels-sidebar" id="channels">
        <div class="channels-header">Channels</div>
        {{CHANNELS_LIST}}
      </aside>

      <!-- Messages area -->
      <div class="messages-area">
        <div class="messages-header">
          <span class="room-name">#<span id="current-room">main</span></span>
        </div>
        <div class="messages-list" id="messages">
          {{CONTENT}}
        </div>
        <div class="chat-input-area" id="chat-input-area" style="display:none;">
          <input type="text" id="chat-input" placeholder="Type a message..." autocomplete="off">
          <button id="chat-send">Send</button>
        </div>
      </div>
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

<script>
  window.GEOGRAM_DATA = {{DATA_JSON}};
  {{SCRIPTS}}
</script>
</body>
</html>
''';

  static const String _defaultChatStylesCss = r'''
/* Chat styles - extends global Terminimal theme */

/* Chat layout - sidebar + messages */
.chat-layout {
  display: grid;
  grid-template-columns: 180px 1fr;
  gap: 30px;
  width: 100%;
}

/* Channels sidebar */
.channels-sidebar {
  border-right: 1px solid var(--border-color);
  padding-right: 20px;
}

.channels-header {
  font-size: 0.9rem;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  color: var(--accent-alpha-70);
  margin-bottom: 15px;
  padding-bottom: 10px;
  border-bottom: 2px dashed var(--accent);
}

/* Channel items */
.channel-item {
  display: block;
  padding: 8px 0;
  cursor: pointer;
  color: inherit;
  text-decoration: none;
  border-bottom: 1px solid var(--border-color);
}

.channel-item:hover {
  color: var(--accent);
}

.channel-item.active {
  color: var(--accent);
}

.channel-item.active .channel-name::before {
  content: "> ";
  color: var(--accent);
}

.channel-icon {
  color: var(--accent-alpha-70);
  margin-right: 5px;
}

.channel-name {
  font-size: 0.95rem;
}

/* Messages area */
.messages-area {
  min-height: 400px;
  max-height: 70vh;
  display: flex;
  flex-direction: column;
}

.messages-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding-bottom: 15px;
  margin-bottom: 20px;
  border-bottom: 2px dashed var(--accent);
  flex-shrink: 0;
}

.room-name {
  font-size: 1.2rem;
  color: var(--accent);
}

.read-only-badge {
  font-size: 0.8rem;
  padding: 3px 8px;
  background: var(--accent-alpha-20);
  color: var(--accent-alpha-70);
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

/* Messages list */
.messages-list {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
}

/* Individual message - styled like a post */
.message {
  padding: 15px 0;
  border-bottom: 1px solid var(--border-color);
}

.message:last-child {
  border-bottom: none;
}

.message-header {
  display: flex;
  align-items: baseline;
  gap: 10px;
  margin-bottom: 8px;
}

.message-author {
  color: var(--accent);
  font-weight: bold;
}

.message-time {
  font-size: 0.85rem;
  color: var(--accent-alpha-70);
}

.message-content {
  line-height: 1.54;
  word-wrap: break-word;
}

/* Date separator */
.date-separator {
  text-align: center;
  padding: 20px 0;
  color: var(--accent-alpha-70);
  font-size: 0.9rem;
  position: relative;
}

.date-separator::before,
.date-separator::after {
  content: "";
  position: absolute;
  top: 50%;
  width: 30%;
  height: 1px;
  background: var(--border-color);
}

.date-separator::before {
  left: 0;
}

.date-separator::after {
  right: 0;
}

/* Status messages */
.status-message {
  color: var(--accent-alpha-70);
  font-style: italic;
  padding: 10px 0;
}

/* Empty state */
.empty-state {
  text-align: center;
  padding: 40px 0;
  color: var(--accent-alpha-70);
}

/* Scrollbar */
.messages-list::-webkit-scrollbar {
  width: 6px;
}

.messages-list::-webkit-scrollbar-track {
  background: transparent;
}

.messages-list::-webkit-scrollbar-thumb {
  background: var(--accent-alpha-20);
  border-radius: 3px;
}

.messages-list::-webkit-scrollbar-thumb:hover {
  background: var(--accent-alpha-70);
}

/* Chat input area */
.chat-input-area {
  display: flex;
  gap: 8px;
  padding-top: 15px;
  border-top: 1px solid var(--border-color);
  margin-top: 10px;
  flex-shrink: 0;
}

.chat-input-area input {
  flex: 1;
  background: var(--background);
  border: 1px solid var(--border-color);
  color: var(--color);
  padding: 8px 12px;
  font-family: inherit;
  font-size: 0.95rem;
  outline: none;
}

.chat-input-area input:focus {
  border-color: var(--accent);
}

.chat-input-area button {
  background: var(--accent);
  color: var(--background);
  border: none;
  padding: 8px 16px;
  font-family: inherit;
  font-size: 0.95rem;
  cursor: pointer;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.chat-input-area button:hover {
  opacity: 0.85;
}

.chat-input-area button:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}


/* Chat error message */
.chat-error {
  color: #e55;
  font-size: 0.85rem;
  padding-top: 5px;
}

/* ===== Mobile: full-viewport layout ===== */
@media (max-width: 683px) {
  html.chat-page,
  .chat-page body {
    height: 100vh !important;
    height: 100dvh !important;
    overflow: hidden !important;
    margin: 0;
    padding: 0;
  }

  .chat-page .container {
    height: 100vh;
    height: 100dvh;
    min-height: 0 !important;
    overflow: hidden;
    display: flex;
    flex-direction: column;
    box-sizing: border-box;
    padding: 8px 10px 0 10px;
  }

  .chat-page .header {
    flex-shrink: 0;
    margin-bottom: 4px;
  }

  .chat-page .menu {
    display: none;
  }

  .chat-page .content {
    flex: 1;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }

  .chat-page .footer {
    display: none;
  }

  .chat-layout {
    display: flex;
    flex-direction: column;
    gap: 0;
    flex: 1;
    min-height: 0;
  }

  .channels-sidebar {
    border-right: none;
    border-bottom: 1px solid var(--border-color);
    padding-right: 0;
    padding-bottom: 6px;
    margin-bottom: 6px;
    display: flex;
    flex-direction: row;
    gap: 8px;
    overflow-x: auto;
    overflow-y: hidden;
    -webkit-overflow-scrolling: touch;
    flex-shrink: 0;
  }

  .channels-header {
    display: none;
  }

  .channel-item {
    flex-shrink: 0;
    padding: 4px 12px;
    border-bottom: none;
    border: 1px solid var(--border-color);
    border-radius: 16px;
    white-space: nowrap;
    font-size: 0.85rem;
  }

  .channel-item.active {
    border-color: var(--accent);
    background: var(--accent-alpha-20);
  }

  .messages-area {
    flex: 1;
    min-height: 0;
    max-height: none;
  }

  .messages-header {
    padding-bottom: 6px;
    margin-bottom: 6px;
    flex-shrink: 0;
  }

  .messages-list {
    flex: 1;
    min-height: 0;
    -webkit-overflow-scrolling: touch;
  }

  .chat-input-area {
    flex-shrink: 0;
    margin-top: 0;
  }

  .chat-input-area input {
    font-size: 16px;
  }

  .chat-input-area button {
    min-height: 44px;
  }

  .message {
    padding: 8px 0;
  }

  .date-separator {
    padding: 8px 0;
  }
}
''';

  static const String _defaultEventsEventHtml = r'''
<!DOCTYPE html>
<html lang="en" class="events-page">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
  <title>{{TITLE}}</title>
  <style>{{GLOBAL_STYLES}}</style>
  <style>{{APP_STYLES}}</style>
  {{NOSTR_STYLES}}
  <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
</head>
<body>
<div class="container">
  <header class="header">
    <div class="header__inner">
      <div class="header__logo">
        <a href="/events/" style="text-decoration:none">
          <div class="logo">{{LOGO_TEXT}}</div>
        </a>
      </div>
      {{NOSTR_HEADER}}
    </div>
    <nav class="menu">
      <ul class="menu__inner">
        {{MENU_ITEMS}}
      </ul>
    </nav>
  </header>

  <div class="content">
    <div class="post" id="event-detail"></div>
  </div>

  <footer class="footer">
    <div class="footer__inner">
      <div class="copyright">
        <span>powered by geogram</span>
      </div>
    </div>
  </footer>
</div>

<!-- Fullscreen map modal -->
<div class="event-map-modal" id="event-map-modal" style="display:none">
  <button class="event-map-modal-close" onclick="closeEventMap()">&times;</button>
  <div id="event-map-full"></div>
</div>

<!-- Lightbox overlay -->
<div id="lightbox" class="lightbox" style="display:none" onclick="closeLightbox()">
  <img id="lightbox-img" src="" alt="">
  <button class="lightbox-close" onclick="closeLightbox()">&times;</button>
  <button class="lightbox-prev" id="lb-prev" onclick="event.stopPropagation();lbNav(-1)">&lsaquo;</button>
  <button class="lightbox-next" id="lb-next" onclick="event.stopPropagation();lbNav(1)">&rsaquo;</button>
</div>

<script>
  window.GEOGRAM_EVENT = {{DATA_JSON}};
  {{SCRIPTS}}

  'use strict';
  (function() {
    var ev = window.GEOGRAM_EVENT || {};
    var detailEl = document.getElementById('event-detail');

    function esc(s) {
      var el = document.createElement('span');
      el.textContent = s || '';
      return el.innerHTML;
    }

    function formatDate(iso) {
      if (!iso) return '';
      var d = new Date(iso.replace(/_/g, ':'));
      return d.toLocaleDateString(undefined, { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });
    }

    function formatShortDate(iso) {
      if (!iso) return '';
      var d = new Date(iso.replace(/_/g, ':'));
      return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
    }

    function formatDateTime(iso) {
      if (!iso) return '';
      var d = new Date(iso.replace(/_/g, ':'));
      if (d.getHours() === 0 && d.getMinutes() === 0) return formatDate(iso);
      return d.toLocaleDateString(undefined, { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' }) +
        ' at ' + d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
    }

    function fileUrl(filename) {
      // Build a path relative to the current page so the station's per-
      // callsign prefix (/{callsign}/events/{id}) is preserved. Hard-coding
      // "/events/..." would 404 on a station that mounts each device under
      // its own callsign namespace.
      var base = window.location.pathname.replace(/\/$/, '');
      return base + '/files/' + encodeURIComponent(filename);
    }

    function thumbUrl(filename) {
      // Use ?thumb=1 so the desktop returns a small (~480px) JPEG instead of
      // the full original. Used by the gallery grid; the lightbox keeps
      // calling fileUrl() so the user gets the high-resolution image when
      // they actually open one.
      return fileUrl(filename) + '?thumb=1';
    }

    // When a thumbnail request fails (socket reset mid-transfer,
    // isolate pool saturated, transient error) retry once after a
    // short backoff, then fall back to the full-resolution original
    // so users always see the photo.
    window.retryGalleryImg = function(imgEl) {
      var n = parseInt(imgEl.getAttribute('data-retry') || '0', 10);
      imgEl.setAttribute('data-retry', String(n + 1));
      if (n === 0) {
        setTimeout(function() {
          imgEl.src = imgEl.getAttribute('data-thumb') + '&_r=' + Date.now();
        }, 1500);
      } else if (n === 1) {
        imgEl.src = imgEl.getAttribute('data-full');
      } else {
        imgEl.onerror = null;
        imgEl.style.display = 'none';
      }
    };

    // === Build page ===
    var html = '';

    // SVG icons (monochrome, inherits currentColor)
    var svgSize = 'width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"';
    var ico = {
      calendar: '<svg ' + svgSize + '><rect x="3" y="4" width="18" height="18" rx="2"/><line x1="16" y1="2" x2="16" y2="6"/><line x1="8" y1="2" x2="8" y2="6"/><line x1="3" y1="10" x2="21" y2="10"/></svg>',
      pin:      '<svg ' + svgSize + '><path d="M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 1 1 18 0z"/><circle cx="12" cy="10" r="3"/></svg>',
      globe:    '<svg ' + svgSize + '><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>',
      user:     '<svg ' + svgSize + '><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>',
      check:    '<svg ' + svgSize + '><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>',
      heart0:   '<svg ' + svgSize + '><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/></svg>',
      heart1:   '<svg ' + svgSize.replace('fill="none"', 'fill="currentColor"') + '><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/></svg>',
      arrow:    '<svg ' + svgSize + ' width="12" height="12"><line x1="7" y1="17" x2="17" y2="7"/><polyline points="7 7 17 7 17 17"/></svg>',
      expand:   '<svg ' + svgSize + '><polyline points="15 3 21 3 21 9"/><polyline points="9 21 3 21 3 15"/><line x1="21" y1="3" x2="14" y2="10"/><line x1="3" y1="21" x2="10" y2="14"/></svg>',
      upload:   '<svg ' + svgSize + '><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg>'
    };

    // Accumulator that the lightbox uses for its image list. Photos
    // come first, then any approved contributor files appended in
    // order. openLightbox / lbNav index into this same array.
    var lbImagesAccum = (gallery || []).slice();

    // --- Request-access banner ---
    // Server flips `access_request_required` to true on a request_access
    // event when the viewer is not on the allow list. The page payload is
    // stripped to a teaser; surface a clear explanation + a button that
    // POSTs the visitor's NOSTR identity to the request endpoint.
    if (ev.access_request_required) {
      var promptHtml = '';
      if (ev.access_request_prompt && ev.access_request_prompt.trim()) {
        promptHtml =
          '<div class="event-request-access-prompt">' +
          esc(ev.access_request_prompt).replace(/\n/g, '<br>') +
          '</div>';
      }
      html += '<div id="event-request-access" class="event-request-access">' +
        '<div class="event-request-access-title">This event is access-controlled</div>' +
        '<div class="event-request-access-msg">' +
          'Ask the organiser for access. They\'ll see your NOSTR identity ' +
          '(' + (window.GeogramNostr && window.GeogramNostr.callsign ? window.GeogramNostr.callsign : 'connecting…') + ') ' +
          'plus your note in their pending requests list.' +
        '</div>' +
        promptHtml +
        '<textarea id="event-request-note" class="event-request-note" rows="3" maxlength="500" ' +
          'placeholder="Add a note: who you are, why you want access…"></textarea>' +
        '<div class="event-request-access-actions">' +
          '<button id="event-request-btn" class="event-request-btn" disabled>' +
            'Request access' +
          '</button>' +
          '<span id="event-request-status" class="event-request-status"></span>' +
        '</div>' +
      '</div>';
    }

    // --- Hero ---
    html += '<div class="event-hero">';
    html += '<h1 class="event-hero-title">' + esc(ev.title) + '</h1>';

    // Date
    if (ev.start_date && ev.end_date && ev.start_date !== ev.end_date) {
      html += '<div class="event-hero-meta"><span class="event-hero-meta-icon">' + ico.calendar + '</span> ' + formatDate(ev.start_date) + ' &mdash; ' + formatDate(ev.end_date) + '</div>';
    } else if (ev.start_date) {
      html += '<div class="event-hero-meta"><span class="event-hero-meta-icon">' + ico.calendar + '</span> ' + formatDate(ev.start_date) + '</div>';
    } else if (ev.timestamp) {
      html += '<div class="event-hero-meta"><span class="event-hero-meta-icon">' + ico.calendar + '</span> ' + formatDateTime(ev.timestamp) + '</div>';
    }

    // Location
    var hasCoords = ev.location && ev.location !== 'online' && ev.location.indexOf(',') !== -1;
    if (ev.location_name) {
      html += '<div class="event-hero-meta"><span class="event-hero-meta-icon">' + ico.pin + '</span> ' + esc(ev.location_name) + '</div>';
    } else if (ev.location === 'online') {
      html += '<div class="event-hero-meta"><span class="event-hero-meta-icon">' + ico.globe + '</span> Online</div>';
    } else if (hasCoords) {
      var parts = ev.location.split(',');
      html += '<div class="event-hero-meta"><span class="event-hero-meta-icon">' + ico.pin + '</span> ' + parts[0].trim() + ', ' + parts[1].trim() + '</div>';
    }

    // Embedded map (when coordinates exist — either from location or linked place)
    var lat = null, lon = null;
    if (hasCoords) {
      var cparts = ev.location.split(',');
      lat = parseFloat(cparts[0].trim());
      lon = parseFloat(cparts[1].trim());
    } else if (ev.place_latitude != null && ev.place_longitude != null) {
      lat = ev.place_latitude;
      lon = ev.place_longitude;
    }
    var hasMap = lat !== null && lon !== null && !isNaN(lat) && !isNaN(lon);
    if (hasMap) {
      html += '<div class="event-map-wrap"><div id="event-map"></div>' +
        '<button class="event-map-expand" onclick="openEventMap()" title="Fullscreen map">' + ico.expand + '</button></div>';
      // Copyable coordinates row
      var coordStr = lat.toFixed(6) + ', ' + lon.toFixed(6);
      html += '<div class="event-coords" onclick="copyCoords()" title="Copy coordinates">' +
        '<span class="event-coords-icon"><svg ' + svgSize + '><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg></span>' +
        '<span>' + coordStr + '</span></div>';
    }

    // Author
    if (ev.author) {
      html += '<div class="event-hero-meta"><span class="event-hero-meta-icon">' + ico.user + '</span> ' + esc(ev.author) + '</div>';
    }

    // Signed badge
    if (ev.signature) {
      html += '<div class="event-hero-meta event-signed"><span class="event-hero-meta-icon">' + ico.check + '</span> Signed with NOSTR</div>';
    }

    html += '</div>'; // .event-hero

    // --- Photo Gallery ---
    // Prefer the new `photos` field; fall back to legacy `flyers` for
    // older event payloads still in the mirror.
    var gallery = (ev.photos && ev.photos.length > 0) ? ev.photos
                : ((ev.flyers && ev.flyers.length > 0) ? ev.flyers : []);
    if (gallery.length > 0) {
      html += '<div class="event-gallery">';
      gallery.forEach(function(f, i) {
        // onerror: first failure retries the thumbnail after 1.5s
        // (may still be generating in the station\'s isolate pool);
        // second failure falls back to the full-resolution file so
        // the user always sees the photo even if the thumbnailer
        // is misbehaving.
        html += '<div class="event-gallery-item" onclick="openLightbox(' + i + ')">' +
          '<img src="' + thumbUrl(f) + '" ' +
            'data-full="' + fileUrl(f) + '" ' +
            'data-thumb="' + thumbUrl(f) + '" ' +
            'data-retry="0" ' +
            'alt="Event photo" loading="lazy" ' +
            'onerror="retryGalleryImg(this)">' +
        '</div>';
      });
      html += '</div>';
    }

    // --- Contributed by (visitor submissions, approved) ---
    // Renders one block per contributor with their thumbnail strip.
    // Files live at `contributors/{CALLSIGN}/<file>` inside the
    // event folder so fileUrl()/thumbUrl() work without changes.
    var contributors = (ev.contributors && ev.contributors.length > 0)
                       ? ev.contributors : [];
    if (contributors.length > 0) {
      contributors.forEach(function(c) {
        if (!c || !c.callsign || !c.files || c.files.length === 0) return;
        html += '<div class="event-section event-contributor">';
        html += '<h3 class="event-contributor-title">Contributed by ' + esc(c.callsign) + '</h3>';
        if (c.description) {
          html += '<p class="event-contributor-desc">' + esc(c.description) + '</p>';
        }
        html += '<div class="event-gallery">';
        c.files.forEach(function(f, i) {
          var rel = 'contributors/' + c.callsign + '/' + f;
          // Track the per-contributor index in a data-attribute so
          // openLightbox can include these in the same lightbox
          // sequence after the main photos.
          var lbIdx = (lbImagesAccum.length);
          lbImagesAccum.push(rel);
          html += '<div class="event-gallery-item" onclick="openLightbox(' + lbIdx + ')">' +
            '<img src="' + thumbUrl(rel) + '" ' +
              'data-full="' + fileUrl(rel) + '" ' +
              'data-thumb="' + thumbUrl(rel) + '" ' +
              'data-retry="0" ' +
              'alt="Contributed photo" loading="lazy" ' +
              'onerror="retryGalleryImg(this)">' +
          '</div>';
        });
        html += '</div></div>';
      });
    }

    // --- Contribute media CTA (NOSTR-signed upload) ---
    // Visible only when window.nostr is available (NIP-07 extension).
    // The button opens a hidden file input; each picked file is
    // hashed (SHA-256), tagged + signed in the browser, persisted to
    // IndexedDB, and uploaded by a background queue with exponential
    // backoff. The contributing device often goes offline for
    // minutes (mobile / weak link) so we keep retrying — closing
    // the tab and reopening it later resumes any queued uploads.
    html += '<div class="event-section event-contribute" id="event-contribute" style="display:none">' +
      '<button class="event-contribute-btn" id="contribute-btn" type="button">' +
        ico.upload + ' <span>Contribute media</span>' +
      '</button>' +
      '<div class="event-contribute-help">Photos and short videos sent here go to the event author for approval before they appear publicly. Uploads are kept in your browser until they reach the device, even if you close this tab.</div>' +
      '<div id="contribute-status" class="event-contribute-status" style="display:none"></div>' +
      '<div id="contribute-queue" class="event-contribute-queue" style="display:none"></div>' +
      '<input type="file" id="contribute-input" accept="image/*,video/*" multiple style="display:none">' +
    '</div>';

    // --- Registration Stats (going/interested only) ---
    var likeCount = ev.feedback_like_count || (ev.likes ? ev.likes.length : 0);
    var statsItems = [];
    var reg = ev.registration;
    if (reg) {
      var goingCount = reg.going ? reg.going.length : 0;
      var interestedCount = reg.interested ? reg.interested.length : 0;
      if (goingCount > 0) statsItems.push('<span class="event-stat"><span class="event-stat-num">' + goingCount + '</span> going</span>');
      if (interestedCount > 0) statsItems.push('<span class="event-stat"><span class="event-stat-num">' + interestedCount + '</span> interested</span>');
    }
    var viewCount = (ev.view_count != null) ? ev.view_count : 0;
    // Always render the view stat with a stable id so the self-post can
    // increment it in place when the visitor's view is recorded.
    statsItems.push(
      '<span id="event-view-stat" class="event-stat"' +
      (viewCount > 0 ? '' : ' style="display:none"') + '>' +
      '<span class="event-stat-num">' + viewCount + '</span> view' +
      (viewCount === 1 ? '' : 's') + '</span>'
    );

    if (statsItems.length > 0) {
      html += '<div class="event-stats-bar">' + statsItems.join('<span class="event-stat-sep">&middot;</span>') + '</div>';
    }

    // --- Like button ---
    html += '<div class="feedback-section" id="feedback-section">' +
      '<button class="like-button" id="like-button" onclick="toggleLike()" disabled>' +
        '<span id="like-icon">' + ico.heart0 + '</span> <span>Like</span>' +
      '</button>' +
      '<span class="like-count" id="like-count">' + (likeCount > 0 ? likeCount + ' like' + (likeCount !== 1 ? 's' : '') : '') + '</span>' +
      '<span class="like-hint" id="like-hint">Connect with Nostr to like</span>' +
    '</div>';

    // --- Description ---
    if (ev.content && ev.content.trim()) {
      html += '<div class="event-section">' +
        '<h2>About</h2>' +
        '<div class="event-body">' + esc(ev.content).replace(/\n\n/g, '</p><p>').replace(/\n/g, '<br>') + '</div>' +
      '</div>';
    }

    // --- Agenda ---
    if (ev.agenda && ev.agenda.trim()) {
      html += '<div class="event-section">' +
        '<h2>Agenda</h2>' +
        '<div class="event-body event-agenda-content">' + esc(ev.agenda).replace(/\n\n/g, '</p><p>').replace(/\n/g, '<br>') + '</div>' +
      '</div>';
    }

    // --- Links ---
    if (ev.links && ev.links.length > 0) {
      html += '<div class="event-section"><h2>Links</h2><div class="event-links-list">';
      ev.links.forEach(function(l) {
        html += '<div class="event-link-card">' +
          '<a href="' + esc(l.url) + '" target="_blank" rel="noopener" class="event-link-url">' + esc(l.description || l.url) + ' ' + ico.arrow + '</a>';
        if (l.description && l.url !== l.description) {
          html += '<div class="event-link-domain">' + esc(l.url.replace(/^https?:\/\//, '').split('/')[0]) + '</div>';
        }
        if (l.note) {
          html += '<div class="event-link-note">' + esc(l.note) + '</div>';
        }
        html += '</div>';
      });
      html += '</div></div>';
    }

    // --- Updates ---
    if (ev.updates && ev.updates.length > 0) {
      html += '<div class="event-section"><h2>Updates</h2>';
      ev.updates.forEach(function(u) {
        var updateMeta = [];
        if (u.author) updateMeta.push(esc(u.author));
        if (u.posted) updateMeta.push(formatShortDate(u.posted));
        html += '<article class="event-update-card">' +
          '<div class="event-update-title">' + esc(u.title) + '</div>' +
          (updateMeta.length ? '<div class="event-update-meta">' + updateMeta.join(' &middot; ') + '</div>' : '') +
          '<div class="event-update-body">' + esc(u.content).replace(/\n/g, '<br>') + '</div>';
        var uStats = [];
        if (u.like_count > 0) uStats.push(u.like_count + ' like' + (u.like_count !== 1 ? 's' : ''));
        if (u.comment_count > 0) uStats.push(u.comment_count + ' comment' + (u.comment_count !== 1 ? 's' : ''));
        if (uStats.length) html += '<div class="event-update-stats">' + uStats.join(' &middot; ') + '</div>';
        html += '</article>';
      });
      html += '</div>';
    }

    // --- Comments ---
    // Render the section whenever there's something to show OR the author
    // has explicitly allowed visitors to add new ones. The compose form
    // appears at the bottom (or "comments disabled" line if the author
    // turned it off).
    var commentsAllowed = ev.comments_enabled !== false;
    var commentsList = (ev.comments && ev.comments.length) ? ev.comments : [];
    if (commentsList.length > 0 || commentsAllowed) {
      html += '<div class="event-section" id="event-comments-section">';
      html += '<h2>Comments (<span id="event-comment-count">' + commentsList.length + '</span>)</h2>';
      html += '<div id="event-comments-list">';
      if (commentsList.length === 0) {
        html += '<div class="event-comments-disabled" id="event-comments-empty">No comments yet — be the first.</div>';
      } else {
        commentsList.forEach(function(c) {
          // data-* attrs let the post-render JS show a tiny delete chip on
          // cards the visitor is allowed to remove (own comment, or the
          // event author deleting any).
          html += '<div class="event-comment-card" data-comment-id="' + esc(c.id || '') + '" data-comment-npub="' + esc(c.npub || '') + '">' +
            '<div class="event-comment-author">' + esc(c.author) +
              '<span class="event-comment-time">' + formatShortDate(c.timestamp) + '</span>' +
              '<button class="event-comment-delete" style="display:none" title="Delete">&times;</button>' +
            '</div>' +
            '<div class="event-comment-text">' + esc(c.content) + '</div>' +
          '</div>';
        });
      }
      html += '</div>';

      if (commentsAllowed) {
        html += '<div class="event-comment-compose" id="event-comment-compose">' +
          '<textarea id="event-comment-text" placeholder="Write a comment…"></textarea>' +
          '<div class="event-comment-compose-row">' +
            '<span class="event-comment-compose-hint" id="event-comment-hint">Connect with NOSTR to comment.</span>' +
            '<button id="event-comment-submit" disabled>Post comment</button>' +
          '</div>' +
        '</div>';
      } else {
        html += '<div class="event-comments-disabled">Comments are disabled by the author.</div>';
      }
      html += '</div>';
    }

    // --- Contacts ---
    if (ev.contacts && ev.contacts.length > 0) {
      html += '<div class="event-section"><h2>People</h2><div class="event-contacts">';
      ev.contacts.forEach(function(c) {
        html += '<span class="event-contact-badge">' + esc(c) + '</span>';
      });
      html += '</div></div>';
    }

    detailEl.innerHTML = html;

    // === Lightbox ===
    // lbImagesAccum was populated above (event photos first, then
    // approved contributor files). Map to fully-qualified file URLs.
    var lbImages = lbImagesAccum.map(fileUrl);
    var lbIndex = 0;
    // Keep prefetched Image objects alive so the browser does not GC
    // them before we navigate to that slide.
    var lbPrefetch = {};
    function lbPrefetchAround(i) {
      if (lbImages.length < 2) return;
      var offsets = [1, -1, 2];
      for (var k = 0; k < offsets.length; k++) {
        var idx = (i + offsets[k] + lbImages.length) % lbImages.length;
        if (lbPrefetch[idx]) continue;
        var img = new Image();
        img.src = lbImages[idx];
        lbPrefetch[idx] = img;
      }
    }

    window.openLightbox = function(i) {
      lbIndex = i;
      var lb = document.getElementById('lightbox');
      document.getElementById('lightbox-img').src = lbImages[lbIndex];
      lb.style.display = 'flex';
      document.getElementById('lb-prev').style.display = lbImages.length > 1 ? '' : 'none';
      document.getElementById('lb-next').style.display = lbImages.length > 1 ? '' : 'none';
      document.body.style.overflow = 'hidden';
      lbPrefetchAround(lbIndex);
    };
    window.closeLightbox = function() {
      document.getElementById('lightbox').style.display = 'none';
      document.body.style.overflow = '';
    };
    window.lbNav = function(dir) {
      lbIndex = (lbIndex + dir + lbImages.length) % lbImages.length;
      document.getElementById('lightbox-img').src = lbImages[lbIndex];
      lbPrefetchAround(lbIndex);
    };
    document.addEventListener('keydown', function(e) {
      var lb = document.getElementById('lightbox');
      if (lb.style.display === 'none') return;
      if (e.key === 'Escape') closeLightbox();
      if (e.key === 'ArrowLeft') lbNav(-1);
      if (e.key === 'ArrowRight') lbNav(1);
    });

    // === Like button (reuses blog NOSTR likes pattern) ===
    var likedPubkeys = ev.feedback_liked_hex_pubkeys || [];
    var userPubkey = null;
    var isLiked = false;

    function onNostrConnected(pubkey) {
      userPubkey = pubkey;
      document.getElementById('like-button').disabled = false;
      var hint = document.getElementById('like-hint');
      if (hint) hint.style.display = 'none';
      if (likedPubkeys.includes(pubkey)) {
        isLiked = true;
        updateLikeUI(ev.feedback_like_count || (ev.likes ? ev.likes.length : 0));
      }
    }

    window.toggleLike = async function() {
      if (!userPubkey || !window.nostr) {
        alert('Please connect with Nostr first');
        return;
      }
      var button = document.getElementById('like-button');
      button.disabled = true;
      try {
        var unsignedEvent = {
          pubkey: userPubkey,
          created_at: Math.floor(Date.now() / 1000),
          kind: 7,
          tags: [['e', ev.id], ['type', 'likes']],
          content: 'like'
        };
        if (ev.npub) unsignedEvent.tags.push(['p', ev.npub]);
        var signedEvent = await window.nostr.signEvent(unsignedEvent);
        if (!signedEvent || !signedEvent.sig) throw new Error('Signing cancelled');
        var response = await fetch('../api/events/' + encodeURIComponent(ev.id) + '/like', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(signedEvent)
        });
        var result = await response.json();
        if (result.success) {
          isLiked = result.liked;
          updateLikeUI(result.like_count);
        }
      } catch (e) { console.error('Error toggling like:', e); }
      finally { button.disabled = false; }
    };

    function updateLikeUI(count) {
      var button = document.getElementById('like-button');
      var icon = document.getElementById('like-icon');
      var countEl = document.getElementById('like-count');
      if (isLiked) { button.classList.add('liked'); } else { button.classList.remove('liked'); }
      icon.innerHTML = isLiked ? ico.heart1 : ico.heart0;
      countEl.textContent = count > 0 ? count + ' like' + (count !== 1 ? 's' : '') : '';
    }

    // Copy coordinates to clipboard
    window.copyCoords = function() {
      var coordText = lat.toFixed(6) + ', ' + lon.toFixed(6);
      if (navigator.clipboard) {
        navigator.clipboard.writeText(coordText);
      } else {
        var ta = document.createElement('textarea');
        ta.value = coordText;
        document.body.appendChild(ta);
        ta.select();
        document.execCommand('copy');
        document.body.removeChild(ta);
      }
      var toast = document.createElement('div');
      toast.className = 'event-coords-toast';
      toast.textContent = 'Coordinates copied';
      document.body.appendChild(toast);
      setTimeout(function() { toast.remove(); }, 1600);
    };

    // Store coordinates globally for map init
    window._eventLat = lat;
    window._eventLon = lon;
    window._hasMap = hasMap;

    // Init: listen for Nostr connection
    document.addEventListener('nostr-connected', function(e) {
      onNostrConnected(e.detail.pubkey);
    });
    if (window.GeogramNostr && window.GeogramNostr.connected && window.GeogramNostr.pubkey) {
      onNostrConnected(window.GeogramNostr.pubkey);
    }

    // ── Page-view counter ─────────────────────────────────────────────
    // Sign and POST a NOSTR view event once the visitor has an identity.
    // The shared nostr_login_scripts auto-bootstraps an identity (extension
    // → stored privkey → freshly-generated keypair) so this fires for
    // every visitor without requiring a manual click.
    var viewRecorded = false;
    async function recordEventView() {
      if (viewRecorded) return;
      if (!window.nostr || typeof window.nostr.signEvent !== 'function') return;
      var nostr = window.GeogramNostr || {};
      if (!nostr.connected || !nostr.pubkey) return;
      viewRecorded = true;
      try {
        var signed = await window.nostr.signEvent({
          kind: 1,
          created_at: Math.floor(Date.now() / 1000),
          tags: [
            ['t', 'event-view'],
            ['e_id', ev.id],
            ['callsign', nostr.callsign || ''],
          ],
          content: '',
        });
        if (!signed || !signed.sig) return;
        var resp = await fetch(
          '../api/feedback/event/' + encodeURIComponent(ev.id) + '/view',
          {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(signed),
          }
        );
        if (!resp.ok) return;
        var result = await resp.json();
        var total = result.total_views;
        if (typeof total !== 'number') return;
        var node = document.getElementById('event-view-stat');
        if (!node) return;
        node.style.display = '';
        node.innerHTML =
          '<span class="event-stat-num">' + total + '</span> view' +
          (total === 1 ? '' : 's');
      } catch (e) {
        console.error('Event view record failed:', e);
      }
    }
    document.addEventListener('nostr-connected', recordEventView);
    if (window.GeogramNostr && window.GeogramNostr.connected) {
      recordEventView();
    }

    // ── Contribute media (visitor → author approval gate) ─────────────
    // Visible only when window.nostr.signEvent is available (NIP-07
    // extension or geogram bootstrap). For each picked file we hash
    // the bytes (SHA-256), build a kind-1 event whose content is the
    // hex digest with tags locking it to (eventId, filename, callsign),
    // ask window.nostr to sign, and POST the raw file bytes through
    // /api/events/{id}/contributors/{CALLSIGN}/submit/{filename}.
    // Server rebuilds the same event and verifies — tampering or a
    // mismatched filename invalidates.
    function showContributeIfReady() {
      var section = document.getElementById('event-contribute');
      if (!section) return;
      var nostr = window.GeogramNostr || {};
      if (!nostr.connected || !nostr.callsign ||
          !window.nostr || typeof window.nostr.signEvent !== 'function') {
        return;
      }
      section.style.display = '';
    }
    document.addEventListener('nostr-connected', showContributeIfReady);
    showContributeIfReady();

    async function sha256Hex(bytes) {
      var buf = await crypto.subtle.digest('SHA-256', bytes);
      var arr = Array.from(new Uint8Array(buf));
      return arr.map(function(b) {
        return ('00' + b.toString(16)).slice(-2);
      }).join('');
    }

    // ── Persistent upload queue ────────────────────────────────────
    // Each picked file is hashed + signed at submit-time, then
    // persisted to IndexedDB along with the file Blob. A worker
    // drains the queue with exponential backoff (5 s → 1 h cap),
    // resumes on `online`, and survives tab reloads. Permanent
    // server rejections (400 / 401 / 403 / 415) stop retrying and
    // surface in the queue UI; transient failures (5xx, network)
    // keep going until the device comes back.
    var QUEUE_DB_NAME = 'geogram-event-uploads';
    var QUEUE_STORE = 'pending';
    var QUEUE_DB_VER = 1;
    var BACKOFF_MS = [5000, 15000, 30000, 60000, 120000, 300000, 900000, 1800000, 3600000];
    var queueProcessing = false;
    var queueTimer = null;

    function queueOpen() {
      return new Promise(function(resolve, reject) {
        if (!window.indexedDB) {
          reject(new Error('IndexedDB unavailable'));
          return;
        }
        var req = window.indexedDB.open(QUEUE_DB_NAME, QUEUE_DB_VER);
        req.onupgradeneeded = function() {
          var db = req.result;
          if (!db.objectStoreNames.contains(QUEUE_STORE)) {
            db.createObjectStore(QUEUE_STORE, { keyPath: 'id' });
          }
        };
        req.onsuccess = function() { resolve(req.result); };
        req.onerror = function() { reject(req.error); };
      });
    }

    function queueAdd(item) {
      return queueOpen().then(function(db) {
        return new Promise(function(resolve, reject) {
          var tx = db.transaction(QUEUE_STORE, 'readwrite');
          tx.objectStore(QUEUE_STORE).add(item);
          tx.oncomplete = function() { resolve(); };
          tx.onerror = function() { reject(tx.error); };
        });
      });
    }

    function queueAll() {
      return queueOpen().then(function(db) {
        return new Promise(function(resolve, reject) {
          var tx = db.transaction(QUEUE_STORE, 'readonly');
          var req = tx.objectStore(QUEUE_STORE).getAll();
          req.onsuccess = function() { resolve(req.result || []); };
          req.onerror = function() { reject(req.error); };
        });
      });
    }

    function queueDelete(id) {
      return queueOpen().then(function(db) {
        return new Promise(function(resolve, reject) {
          var tx = db.transaction(QUEUE_STORE, 'readwrite');
          tx.objectStore(QUEUE_STORE).delete(id);
          tx.oncomplete = function() { resolve(); };
          tx.onerror = function() { reject(tx.error); };
        });
      });
    }

    function queueUpdate(id, patch) {
      return queueOpen().then(function(db) {
        return new Promise(function(resolve, reject) {
          var tx = db.transaction(QUEUE_STORE, 'readwrite');
          var store = tx.objectStore(QUEUE_STORE);
          var req = store.get(id);
          req.onsuccess = function() {
            var rec = req.result;
            if (!rec) { resolve(); return; }
            for (var k in patch) rec[k] = patch[k];
            store.put(rec);
          };
          tx.oncomplete = function() { resolve(); };
          tx.onerror = function() { reject(tx.error); };
        });
      });
    }

    function isPermanentStatus(code) {
      // Bad request, missing/invalid signature, type rejection,
      // payload too large — retrying would never help.
      return code === 400 || code === 401 || code === 403 ||
             code === 413 || code === 415;
    }

    async function tryUploadItem(item) {
      // Only this event\'s queue; other events served from the same
      // origin keep their own items but we ignore them here.
      if (item.eventId !== ev.id) {
        return { skipped: true };
      }
      var url = '../api/events/' + encodeURIComponent(item.eventId) +
                '/contributors/' + encodeURIComponent(item.callsign) +
                '/submit/' + encodeURIComponent(item.filename);
      try {
        var resp = await fetch(url, {
          method: 'POST',
          headers: {
            'Content-Type': item.contentType || 'application/octet-stream',
            'X-Nostr-Npub': item.npub,
            'X-Nostr-Signature': item.signature,
            'X-Nostr-Timestamp': String(item.createdAt),
          },
          body: item.bytes,
        });
        if (resp.ok) return { done: true };
        var err = '';
        try { err = (await resp.json()).error || ''; } catch (_) {}
        return {
          permanent: isPermanentStatus(resp.status),
          error: err || ('HTTP ' + resp.status),
        };
      } catch (e) {
        // Network error / offline — always retry.
        return { error: e && e.message ? e.message : String(e) };
      }
    }

    function backoffFor(attempts) {
      var idx = Math.min(attempts, BACKOFF_MS.length - 1);
      return BACKOFF_MS[idx];
    }

    async function processQueue() {
      if (queueProcessing) return;
      queueProcessing = true;
      try {
        var items = await queueAll();
        var now = Date.now();
        var nextWake = null;
        for (var i = 0; i < items.length; i++) {
          var item = items[i];
          if (item.eventId !== ev.id) continue;
          if (item.status === 'failed') continue;
          if (item.nextAttempt && item.nextAttempt > now) {
            if (nextWake === null || item.nextAttempt < nextWake) {
              nextWake = item.nextAttempt;
            }
            continue;
          }
          await queueUpdate(item.id, { status: 'uploading' });
          renderQueueUI();
          var result = await tryUploadItem(item);
          if (result.done) {
            await queueDelete(item.id);
          } else if (result.permanent) {
            await queueUpdate(item.id, {
              status: 'failed',
              lastError: result.error,
              attempts: (item.attempts || 0) + 1,
            });
          } else {
            var attempts = (item.attempts || 0) + 1;
            var delay = backoffFor(attempts - 1);
            var nextAt = Date.now() + delay;
            await queueUpdate(item.id, {
              status: 'queued',
              attempts: attempts,
              nextAttempt: nextAt,
              lastError: result.error,
            });
            if (nextWake === null || nextAt < nextWake) nextWake = nextAt;
          }
          renderQueueUI();
        }
        if (nextWake !== null) {
          var ms = Math.max(1000, nextWake - Date.now());
          if (queueTimer) clearTimeout(queueTimer);
          queueTimer = setTimeout(processQueue, ms);
        }
      } catch (e) {
        // IDB unavailable / quota — log and back off.
        console.warn('processQueue failed:', e);
      } finally {
        queueProcessing = false;
      }
    }

    function setContributeStatus(msg, isError) {
      var status = document.getElementById('contribute-status');
      if (!status) return;
      status.style.display = msg ? '' : 'none';
      status.textContent = msg || '';
      status.style.color = isError ? '#c33' : '';
    }

    async function renderQueueUI() {
      var container = document.getElementById('contribute-queue');
      if (!container) return;
      var items;
      try {
        items = (await queueAll()).filter(function(i) {
          return i.eventId === ev.id;
        });
      } catch (_) {
        container.style.display = 'none';
        return;
      }
      if (items.length === 0) {
        container.style.display = 'none';
        container.innerHTML = '';
        return;
      }
      items.sort(function(a, b) { return a.queuedAt - b.queuedAt; });
      var rows = items.map(function(item) {
        var label;
        if (item.status === 'uploading') {
          label = 'Uploading…';
        } else if (item.status === 'failed') {
          label = 'Failed: ' + (item.lastError || 'unknown error');
        } else if (item.attempts && item.attempts > 0) {
          var wait = Math.max(0, (item.nextAttempt || 0) - Date.now());
          var secs = Math.ceil(wait / 1000);
          label = 'Retrying in ' + secs + 's (attempt ' + (item.attempts + 1) + ')';
          if (item.lastError) label += ' — ' + item.lastError;
        } else {
          label = 'Queued';
        }
        var actions = '';
        if (item.status !== 'uploading') {
          actions += '<button class="event-contribute-mini" data-act="retry" data-id="' +
            esc(item.id) + '">Retry now</button>';
        }
        actions += '<button class="event-contribute-mini" data-act="remove" data-id="' +
          esc(item.id) + '">Remove</button>';
        return '<div class="event-contribute-item">' +
          '<div class="event-contribute-item-name">' + esc(item.filename) + '</div>' +
          '<div class="event-contribute-item-status">' + esc(label) + '</div>' +
          '<div class="event-contribute-item-actions">' + actions + '</div>' +
        '</div>';
      });
      container.innerHTML =
        '<div class="event-contribute-summary">' + items.length +
          ' upload(s) waiting on the device</div>' +
        rows.join('');
      container.style.display = '';

      // Wire per-item buttons.
      var btns = container.querySelectorAll('button[data-act]');
      for (var i = 0; i < btns.length; i++) {
        (function(btn) {
          btn.onclick = async function() {
            var id = btn.getAttribute('data-id');
            var act = btn.getAttribute('data-act');
            if (act === 'remove') {
              await queueDelete(id);
            } else if (act === 'retry') {
              await queueUpdate(id, {
                attempts: 0,
                nextAttempt: 0,
                status: 'queued',
                lastError: null,
              });
              processQueue();
            }
            renderQueueUI();
          };
        })(btns[i]);
      }
    }

    async function enqueueContribution(file, callsign) {
      var bytes = new Uint8Array(await file.arrayBuffer());
      var hash = await sha256Hex(bytes);
      var createdAt = Math.floor(Date.now() / 1000);
      var unsigned = {
        kind: 1,
        created_at: createdAt,
        tags: [
          ['e', ev.id],
          ['f', file.name],
          ['callsign', callsign],
          ['kind', 'event_contribution'],
        ],
        content: hash,
      };
      var signed = await window.nostr.signEvent(unsigned);
      if (!signed || !signed.sig || !signed.pubkey) {
        throw new Error('Signing failed');
      }
      var npub = (window.NostrTools &&
                  window.NostrTools.nip19 &&
                  window.NostrTools.nip19.npubEncode)
        ? window.NostrTools.nip19.npubEncode(signed.pubkey)
        : signed.pubkey;
      // IDB stores Blobs natively — keep the original Blob so large
      // videos don\'t balloon in memory as base64.
      var blob = new Blob([bytes], { type: file.type || 'application/octet-stream' });
      var id = String(Date.now()) + '-' + Math.random().toString(36).slice(2, 10);
      await queueAdd({
        id: id,
        eventId: ev.id,
        callsign: callsign,
        filename: file.name,
        contentType: file.type || 'application/octet-stream',
        bytes: blob,
        npub: npub,
        signature: signed.sig,
        createdAt: createdAt,
        queuedAt: Date.now(),
        attempts: 0,
        nextAttempt: 0,
        lastError: null,
        status: 'queued',
      });
    }

    function bindContributeUploader() {
      var btn = document.getElementById('contribute-btn');
      var input = document.getElementById('contribute-input');
      if (!btn || !input) return;
      btn.onclick = function() { input.click(); };
      input.onchange = async function() {
        var files = Array.from(input.files || []);
        input.value = '';
        if (files.length === 0) return;
        var nostr = window.GeogramNostr || {};
        var callsign = nostr.callsign || '';
        if (!callsign) {
          setContributeStatus('No callsign — connect a NOSTR identity first.', true);
          return;
        }
        btn.disabled = true;
        var enqueued = 0;
        var rejected = [];
        for (var i = 0; i < files.length; i++) {
          var f = files[i];
          try {
            await enqueueContribution(f, callsign);
            enqueued++;
          } catch (err) {
            rejected.push(f.name + ' (' + (err && err.message ? err.message : err) + ')');
          }
        }
        btn.disabled = false;
        if (enqueued > 0) {
          setContributeStatus(
            enqueued + ' file(s) queued. Uploads will keep trying until the device receives them.',
            false
          );
        }
        if (rejected.length > 0) {
          setContributeStatus(
            'Could not queue: ' + rejected.join(', '),
            true
          );
        }
        renderQueueUI();
        processQueue();
      };
    }
    bindContributeUploader();

    // Resume any uploads queued from a previous tab session.
    renderQueueUI();
    processQueue();
    window.addEventListener('online', function() {
      // Reset backoff so a returned connection retries immediately.
      queueAll().then(function(items) {
        var todo = [];
        items.forEach(function(item) {
          if (item.eventId !== ev.id) return;
          if (item.status === 'failed') return;
          todo.push(queueUpdate(item.id, { nextAttempt: 0 }));
        });
        return Promise.all(todo);
      }).then(processQueue).catch(function() {});
    });
    // Safety-net periodic processor in case timers were missed (tab
    // backgrounded / throttled).
    setInterval(function() { processQueue(); }, 60000);

    // ── Request-access button ─────────────────────────────────────────
    // Only present when the server stripped this page to a teaser. POSTs
    // the visitor's NOSTR identity (auto-generated by the shared login
    // bootstrap) to /api/events/{id}/request-access. The owner's desktop
    // sees the entry under {event}/feedback/access_requests.json.
    var requestSent = false;
    function enableRequestButton() {
      var btn = document.getElementById('event-request-btn');
      if (!btn) return;
      btn.disabled = false;
      btn.onclick = sendAccessRequest;
    }
    async function sendAccessRequest() {
      if (requestSent) return;
      var btn = document.getElementById('event-request-btn');
      var status = document.getElementById('event-request-status');
      var noteEl = document.getElementById('event-request-note');
      var nostr = window.GeogramNostr || {};
      if (!nostr.pubkey || !nostr.connected) {
        if (status) status.textContent = 'Connecting…';
        return;
      }
      requestSent = true;
      if (btn) btn.disabled = true;
      if (status) status.textContent = 'Sending…';
      try {
        var npub = (window.NostrTools &&
                    window.NostrTools.nip19 &&
                    window.NostrTools.nip19.npubEncode)
          ? window.NostrTools.nip19.npubEncode(nostr.pubkey)
          : null;
        var note = noteEl ? (noteEl.value || '').trim() : '';
        var resp = await fetch(
          '../api/events/' + encodeURIComponent(ev.id) + '/request-access',
          {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              npub: npub,
              callsign: nostr.callsign || '',
              // Profile nickname (from kind-0 metadata) — server upserts
              // a Contact so the callsign-only "X1HFG3" turns into a
              // recognisable "Joe (X1HFG3)" in the access-control picker.
              nickname: nostr.nickname || '',
              message: note,
            }),
          }
        );
        if (resp.ok) {
          var data;
          try { data = await resp.json(); } catch (e) { data = {}; }
          if (data && data.status === 'approved') {
            if (status) status.textContent = 'Access granted — reload to view.';
          } else if (data && data.status === 'denied') {
            if (status) status.textContent = 'Access previously denied.';
          } else {
            if (status) status.textContent = 'Request sent. Check back later.';
          }
        } else {
          requestSent = false;
          if (btn) btn.disabled = false;
          if (status) status.textContent = 'Failed to send request.';
        }
      } catch (e) {
        requestSent = false;
        if (btn) btn.disabled = false;
        if (status) status.textContent = 'Failed to send request.';
      }
    }
    document.addEventListener('nostr-connected', enableRequestButton);
    if (window.GeogramNostr && window.GeogramNostr.connected) {
      enableRequestButton();
    }

    // ── Comment compose ───────────────────────────────────────────────
    // Sign a kind-1 NOSTR event with the textarea body and POST it to the
    // existing /api/feedback/event/{id}/comment endpoint. The freshly
    // posted comment is prepended to the local list so the visitor sees
    // their own contribution land without a reload.
    function enableCommentForm() {
      var btn = document.getElementById('event-comment-submit');
      var hint = document.getElementById('event-comment-hint');
      if (!btn) return;
      btn.disabled = false;
      if (hint) {
        var nostr = window.GeogramNostr || {};
        var who = nostr.nickname || nostr.callsign || 'connected';
        hint.textContent = 'Posting as ' + who;
      }
      btn.onclick = postEventComment;
    }
    async function postEventComment() {
      var btn = document.getElementById('event-comment-submit');
      var ta = document.getElementById('event-comment-text');
      var hint = document.getElementById('event-comment-hint');
      if (!btn || !ta) return;
      var body = (ta.value || '').trim();
      if (!body) {
        if (hint) hint.textContent = 'Type something first.';
        return;
      }
      var nostr = window.GeogramNostr || {};
      if (!window.nostr || typeof window.nostr.signEvent !== 'function' ||
          !nostr.connected || !nostr.pubkey) {
        if (hint) hint.textContent = 'Connect with NOSTR to comment.';
        return;
      }
      btn.disabled = true;
      if (hint) hint.textContent = 'Signing…';
      try {
        var signed = await window.nostr.signEvent({
          kind: 1,
          created_at: Math.floor(Date.now() / 1000),
          tags: [
            ['t', 'event-comment'],
            ['e_id', ev.id],
          ],
          content: body,
        });
        if (!signed || !signed.sig) {
          if (hint) hint.textContent = 'Signing failed.';
          btn.disabled = false;
          return;
        }
        var npub = (window.NostrTools &&
                    window.NostrTools.nip19 &&
                    window.NostrTools.nip19.npubEncode)
          ? window.NostrTools.nip19.npubEncode(nostr.pubkey)
          : null;
        var resp = await fetch(
          '../api/feedback/event/' + encodeURIComponent(ev.id) + '/comment',
          {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              author: nostr.nickname || nostr.callsign || (npub ? npub.slice(0, 12) : 'anon'),
              content: body,
              npub: npub,
              signature: signed.sig,
            }),
          }
        );
        if (!resp.ok) {
          if (hint) hint.textContent = 'Failed to post (HTTP ' + resp.status + ').';
          btn.disabled = false;
          return;
        }
        // Optimistic insert. Server returns {success, comment_id, timestamp}.
        var ack = {};
        try { ack = await resp.json(); } catch (e) {}
        var ts = ack.timestamp || new Date().toISOString();
        var listEl = document.getElementById('event-comments-list');
        var emptyEl = document.getElementById('event-comments-empty');
        if (emptyEl) emptyEl.remove();
        if (listEl) {
          var card = document.createElement('div');
          card.className = 'event-comment-card';
          if (ack.comment_id) card.setAttribute('data-comment-id', ack.comment_id);
          card.setAttribute('data-comment-npub', npub || '');
          card.innerHTML =
            '<div class="event-comment-author">' + esc(nostr.nickname || nostr.callsign || 'You') +
              '<span class="event-comment-time">just now</span>' +
              '<button class="event-comment-delete" style="display:none" title="Delete">&times;</button>' +
            '</div>' +
            '<div class="event-comment-text">' + esc(body) + '</div>';
          listEl.appendChild(card);
          applyCommentDeleteChips();
        }
        var countEl = document.getElementById('event-comment-count');
        if (countEl) countEl.textContent = (parseInt(countEl.textContent, 10) || 0) + 1;
        ta.value = '';
        if (hint) hint.textContent = 'Posted. Thanks for commenting!';
        btn.disabled = false;
      } catch (e) {
        console.error('Comment post failed:', e);
        if (hint) hint.textContent = 'Failed to post.';
        btn.disabled = false;
      }
    }
    document.addEventListener('nostr-connected', enableCommentForm);
    if (window.GeogramNostr && window.GeogramNostr.connected) {
      enableCommentForm();
    }

    // ── Comment delete ────────────────────────────────────────────────
    // Show the × chip on every card the visitor is allowed to remove:
    // their own comment, or any comment when the visitor is the event
    // author. DELETE /api/feedback/event/{id}/comment/{commentId} is
    // shared between the two stations via FeedbackDeleteHelper.
    function visitorBech32Npub() {
      var nostr = window.GeogramNostr || {};
      if (!nostr.pubkey) return null;
      try {
        if (window.NostrTools && window.NostrTools.nip19 &&
            window.NostrTools.nip19.npubEncode) {
          return window.NostrTools.nip19.npubEncode(nostr.pubkey);
        }
      } catch (e) {}
      return null;
    }
    function applyCommentDeleteChips() {
      var nostr = window.GeogramNostr || {};
      if (!nostr.connected || !nostr.pubkey) return;
      var visitorNpub = visitorBech32Npub();
      var ownerHex = ev.author_pubkey_hex || '';
      var isOwner = ownerHex && ownerHex === nostr.pubkey;
      var cards = document.querySelectorAll('.event-comment-card');
      cards.forEach(function(card) {
        var cnpub = card.getAttribute('data-comment-npub') || '';
        var canDelete = isOwner || (visitorNpub && cnpub === visitorNpub);
        if (!canDelete) return;
        var btn = card.querySelector('.event-comment-delete');
        if (!btn) return;
        btn.style.display = '';
        btn.onclick = function() { deleteEventComment(card); };
      });
    }
    async function deleteEventComment(card) {
      if (!card) return;
      var commentId = card.getAttribute('data-comment-id') || '';
      if (!commentId) return;
      if (!confirm('Delete this comment?')) return;
      var visitorNpub = visitorBech32Npub();
      if (!visitorNpub) {
        alert('Could not derive your npub for the delete request.');
        return;
      }
      try {
        var resp = await fetch(
          '../api/feedback/event/' + encodeURIComponent(ev.id) +
            '/comment/' + encodeURIComponent(commentId),
          {
            method: 'DELETE',
            headers: { 'X-Npub': visitorNpub },
          }
        );
        if (!resp.ok) {
          var msg = 'Delete failed (HTTP ' + resp.status + ')';
          try {
            var err = await resp.json();
            if (err && err.error) msg += ': ' + err.error;
          } catch (e) {}
          alert(msg);
          return;
        }
        card.remove();
        var countEl = document.getElementById('event-comment-count');
        if (countEl) {
          var n = (parseInt(countEl.textContent, 10) || 1) - 1;
          countEl.textContent = n < 0 ? 0 : n;
        }
        // If the list is now empty, surface the "be the first" hint.
        var listEl = document.getElementById('event-comments-list');
        if (listEl && listEl.querySelectorAll('.event-comment-card').length === 0 &&
            !document.getElementById('event-comments-empty')) {
          var empty = document.createElement('div');
          empty.id = 'event-comments-empty';
          empty.className = 'event-comments-disabled';
          empty.textContent = 'No comments yet — be the first.';
          listEl.appendChild(empty);
        }
      } catch (e) {
        console.error('Comment delete failed:', e);
        alert('Delete failed.');
      }
    }
    document.addEventListener('nostr-connected', applyCommentDeleteChips);
    if (window.GeogramNostr && window.GeogramNostr.connected) {
      applyCommentDeleteChips();
    }
  })();
</script>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
'use strict';
(function() {
  if (!window._hasMap) return;
  var lat = window._eventLat;
  var lon = window._eventLon;

  var pinSvg = '<svg width="24" height="36" viewBox="0 0 24 36" xmlns="http://www.w3.org/2000/svg">' +
    '<path d="M12 0C5.4 0 0 5.4 0 12c0 9 12 24 12 24s12-15 12-24C24 5.4 18.6 0 12 0z" fill="var(--accent, #ff7b00)"/>' +
    '<circle cx="12" cy="12" r="5" fill="rgba(0,0,0,0.25)"/></svg>';
  var pinIcon = L.divIcon({
    html: pinSvg,
    className: 'event-map-pin',
    iconSize: [24, 36],
    iconAnchor: [12, 36]
  });

  var satUrl = '/tiles/sat/{z}/{x}/{y}.png?layer=satellite';
  var labelUrl = '/tiles/lbl/{z}/{x}/{y}.png?layer=labels';

  // Small preview map
  var mapEl = document.getElementById('event-map');
  if (mapEl) {
    var smallMap = L.map('event-map', {
      center: [lat, lon],
      zoom: 14,
      zoomControl: false,
      attributionControl: false,
      dragging: false,
      scrollWheelZoom: false,
      doubleClickZoom: false,
      touchZoom: false,
      boxZoom: false,
      keyboard: false
    });
    L.tileLayer(satUrl, { maxZoom: 18 }).addTo(smallMap);
    L.tileLayer(labelUrl, { maxZoom: 18 }).addTo(smallMap);
    L.marker([lat, lon], { icon: pinIcon }).addTo(smallMap);
    mapEl.addEventListener('click', function() { openEventMap(); });
  }

  // Fullscreen map
  var fullMap = null;
  window.openEventMap = function() {
    var modal = document.getElementById('event-map-modal');
    modal.style.display = 'flex';
    document.body.style.overflow = 'hidden';
    if (!fullMap) {
      fullMap = L.map('event-map-full', {
        center: [lat, lon],
        zoom: 15,
        attributionControl: false
      });
      L.tileLayer(satUrl, { maxZoom: 18 }).addTo(fullMap);
      L.tileLayer(labelUrl, { maxZoom: 18 }).addTo(fullMap);
      L.marker([lat, lon], { icon: pinIcon }).addTo(fullMap);
    }
    setTimeout(function() { fullMap.invalidateSize(); }, 100);
  };

  window.closeEventMap = function() {
    document.getElementById('event-map-modal').style.display = 'none';
    document.body.style.overflow = '';
  };

  document.addEventListener('keydown', function(e) {
    if (e.key === 'Escape' && document.getElementById('event-map-modal').style.display !== 'none') {
      closeEventMap();
    }
  });
})();
</script>
</body>
</html>
''';

  static const String _defaultEventsIndexHtml = r'''
<!DOCTYPE html>
<html lang="en" class="events-page">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
  <title>{{TITLE}}</title>
  <style>{{GLOBAL_STYLES}}</style>
  <style>{{APP_STYLES}}</style>
  {{NOSTR_STYLES}}
</head>
<body>
<div class="container">
  <header class="header">
    <div class="header__inner">
      <div class="header__logo">
        <div class="logo">{{LOGO_TEXT}}</div>
      </div>
      {{NOSTR_HEADER}}
    </div>
    <nav class="menu">
      <ul class="menu__inner">
        {{MENU_ITEMS}}
      </ul>
    </nav>
  </header>

  <div class="content">
    <div class="post">
      <input id="events-search" class="events-search" type="text" placeholder="Search events...">
      <div id="events-list"></div>
      <div id="events-hint" class="events-hint" style="display:none"></div>
    </div>
  </div>

  <footer class="footer">
    <div class="footer__inner">
      <div class="copyright">
        <span>powered by geogram</span>
      </div>
    </div>
  </footer>
</div>

<script>
  window.GEOGRAM_EVENTS = {{DATA_JSON}};
  {{SCRIPTS}}

  'use strict';
  (function() {
    var data = window.GEOGRAM_EVENTS || {};
    var listEl = document.getElementById('events-list');
    var hintEl = document.getElementById('events-hint');
    var searchEl = document.getElementById('events-search');

    var allEvents = data.events || [];

    if (!data.authenticated) {
      hintEl.textContent = 'Connect with Nostr to see group events';
      hintEl.style.display = '';
    }

    function esc(s) {
      var el = document.createElement('span');
      el.textContent = s || '';
      return el.innerHTML;
    }

    function formatDate(iso) {
      if (!iso) return '';
      var d = new Date(iso.replace(/_/g, ':'));
      return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
    }

    function formatFullDate(iso) {
      if (!iso) return '';
      var d = new Date(iso.replace(/_/g, ':'));
      return d.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' });
    }

    function getYear(item) {
      var ts = item.start_date || item.timestamp || '';
      return ts.substring(0, 4);
    }

    function isFuture(item) {
      var ts = item.start_date || item.timestamp || '';
      try { return new Date(ts.replace(/_/g, ':')) > new Date(); } catch(e) { return false; }
    }

    function renderEventNode(item) {
      var linkId = item.slug || item.id;
      var date = item.start_date || item.timestamp;
      var dateLabel = formatFullDate(date);
      if (item.start_date && item.end_date && item.start_date !== item.end_date) {
        dateLabel = formatDate(item.start_date) + ' \u2013 ' + formatDate(item.end_date);
      }

      var location = '';
      if (item.location_name) {
        location = esc(item.location_name);
      } else if (item.location === 'online') {
        location = 'Online';
      } else if (item.location && item.location !== 'online') {
        location = 'In-person';
      }

      var stats = [];
      if (item.going_count > 0) stats.push(item.going_count + ' going');
      if (item.interested_count > 0) stats.push(item.interested_count + ' interested');

      var future = isFuture(item);

      return '<a class="tl-node' + (future ? ' tl-future' : '') + '" href="' + encodeURIComponent(linkId) + '">' +
        '<div class="tl-dot"></div>' +
        '<div class="tl-card">' +
          '<div class="tl-title">' + esc(item.title) + '</div>' +
          '<div class="tl-meta">' +
            '<span>' + dateLabel + '</span>' +
            (location ? '<span class="tl-sep">\u00b7</span><span>' + location + '</span>' : '') +
          '</div>' +
          (stats.length ? '<div class="tl-stats">' + stats.join(' \u00b7 ') + '</div>' : '') +
        '</div>' +
      '</a>';
    }

    function render(filter) {
      var filtered = allEvents;

      if (filter) {
        var q = filter.toLowerCase();
        filtered = filtered.filter(function(item) {
          var haystack = (item.title || '') + ' ' + (item.location_name || '') + ' ' + (item.author || '');
          return haystack.toLowerCase().indexOf(q) !== -1;
        });
      }

      if (filtered.length === 0) {
        listEl.innerHTML = '<div class="events-empty">' + (allEvents.length === 0 ? 'No events yet' : 'No matches') + '</div>';
        return;
      }

      // Group by year
      var groups = {};
      var yearOrder = [];
      filtered.forEach(function(item) {
        var y = getYear(item);
        if (!groups[y]) { groups[y] = []; yearOrder.push(y); }
        groups[y].push(item);
      });
      // Sort years descending (newest first), but future events on top
      yearOrder.sort(function(a, b) { return parseInt(b) - parseInt(a); });

      var html = '<div class="timeline">';
      yearOrder.forEach(function(year) {
        html += '<div class="tl-year-group">';
        html += '<div class="tl-year-header"><span class="tl-year-label">' + year + '</span></div>';
        html += '<div class="tl-track">';
        groups[year].forEach(function(item) {
          html += renderEventNode(item);
        });
        html += '</div>';
        html += '</div>';
      });
      html += '</div>';

      listEl.innerHTML = html;
    }

    render('');
    searchEl.addEventListener('input', function() { render(searchEl.value); });

    document.addEventListener('nostr-connected', function() {
      if (!data.authenticated) {
        window.location.reload();
      }
    });
  })();
</script>
</body>
</html>
''';

  static const String _defaultEventsStylesCss = r'''
/* Events App - Listing Page */

/* Search */
.events-search {
  width: 100%;
  padding: 10px 14px;
  border: 1px dashed var(--border-color);
  background: transparent;
  color: var(--color);
  font-size: 1rem;
  font-family: inherit;
  margin-bottom: 30px;
  box-sizing: border-box;
}

.events-search:focus {
  outline: none;
  border-color: var(--accent);
  border-style: solid;
}

.events-search::placeholder {
  color: var(--accent-alpha-70);
}

.events-hint {
  text-align: center;
  opacity: 0.5;
  font-size: 0.9rem;
  padding: 12px;
}

.events-empty {
  text-align: center;
  opacity: 0.4;
  padding: 40px 12px;
}

/* Timeline */
.timeline {
  position: relative;
}

/* Year group */
.tl-year-group {
  margin-bottom: 10px;
}

.tl-year-header {
  display: flex;
  align-items: center;
  margin-bottom: 0;
  position: relative;
}

.tl-year-label {
  display: inline-block;
  font-size: 0.85rem;
  font-weight: 700;
  letter-spacing: 0.1em;
  color: var(--accent);
  background: var(--background);
  padding: 4px 12px;
  border: 2px dashed var(--accent);
  position: relative;
  z-index: 1;
}

/* The vertical track with wire */
.tl-track {
  position: relative;
  padding-left: 28px;
  border-left: 2px dashed var(--border-color);
  margin-left: 18px;
}

/* Event node */
.tl-node {
  display: block;
  position: relative;
  padding: 16px 0;
  text-decoration: none;
  color: inherit;
}

.tl-node:not(:last-child) {
  border-bottom: 1px solid var(--border-color);
}

/* The dot on the wire */
.tl-dot {
  position: absolute;
  left: -34px;
  top: 22px;
  width: 10px;
  height: 10px;
  border-radius: 50%;
  background: var(--border-color);
  border: 2px solid var(--background);
  box-shadow: 0 0 0 2px var(--border-color);
  transition: all 0.15s;
}

.tl-node:hover .tl-dot {
  background: var(--accent);
  box-shadow: 0 0 0 2px var(--accent);
}

/* Future events get accent dot */
.tl-future .tl-dot {
  background: var(--accent);
  box-shadow: 0 0 0 2px var(--accent-alpha-70);
}

/* Card content */
.tl-card {
  transition: transform 0.1s;
}

.tl-node:hover .tl-card {
  transform: translateX(4px);
}

.tl-title {
  font-size: 1.1rem;
  font-weight: 600;
  color: var(--accent);
  margin-bottom: 4px;
  line-height: 1.3;
}

.tl-meta {
  font-size: 0.9rem;
  color: var(--color);
  opacity: 0.6;
}

.tl-sep {
  margin: 0 6px;
  opacity: 0.4;
}

.tl-stats {
  font-size: 0.8rem;
  color: var(--accent-alpha-70);
  margin-top: 4px;
}

@media (max-width: 480px) {
  .tl-track {
    padding-left: 20px;
    margin-left: 12px;
  }
  .tl-dot {
    left: -26px;
    width: 8px;
    height: 8px;
  }
}

/* ========== Event Detail Page ========== */

/* Tighten post wrapper on event detail (overrides global .post) */
.events-page .post {
  margin-top: 0;
  padding-top: 6px;
}

/* Hero */
.event-hero {
  margin-bottom: 30px;
  padding-bottom: 20px;
  border-bottom: 1px solid var(--border-color);
}
.event-request-access {
  background: var(--accent-alpha-20);
  border: 1px solid var(--accent);
  border-radius: 6px;
  padding: 16px;
  margin-bottom: 24px;
}
.event-request-access-title {
  color: var(--accent);
  font-weight: 700;
  margin-bottom: 6px;
}
.event-request-access-msg { font-size: 0.9rem; opacity: 0.85; }
.event-request-access-prompt {
  margin-top: 12px; padding: 10px 12px;
  background: var(--accent-alpha-20);
  border-left: 3px solid var(--accent);
  font-size: 0.9rem;
}
.event-request-note {
  margin-top: 12px;
  width: 100%;
  box-sizing: border-box;
  background: var(--background);
  color: var(--color);
  border: 1px solid var(--border-color);
  border-radius: 4px;
  padding: 8px 10px;
  font-family: inherit;
  font-size: 0.9rem;
  resize: vertical;
}
.event-request-access-actions {
  margin-top: 12px;
  display: flex; align-items: center; gap: 12px;
}
.event-request-btn {
  background: var(--accent); color: var(--background);
  border: none; padding: 6px 14px; cursor: pointer;
  font-family: inherit; font-size: 0.9rem; border-radius: 4px;
}
.event-request-btn[disabled] { opacity: 0.6; cursor: default; }
.event-request-status { font-size: 0.85rem; opacity: 0.85; }

.event-hero-title {
  --border: 2px dashed var(--accent);
  position: relative;
  color: var(--accent);
  font-size: 1.8rem;
  font-weight: 700;
  margin: 0 0 16px 0;
  line-height: 1.3;
}

.event-hero-meta {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 1rem;
  color: var(--color);
  opacity: 0.7;
  margin-bottom: 6px;
  line-height: 1.5;
}

.event-hero-meta-icon {
  flex-shrink: 0;
  width: 16px;
  height: 16px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
}

.event-hero-meta-icon svg {
  vertical-align: middle;
}

.event-hero-meta a {
  color: var(--accent);
  text-decoration: none;
}

.event-hero-meta a:hover {
  text-decoration: underline;
}

.event-signed {
  color: #4ade80;
  opacity: 1;
}

/* Embedded map */
.event-map-wrap {
  position: relative;
  height: 200px;
  border-radius: 6px;
  overflow: hidden;
  margin-top: 12px;
  border: 1px solid var(--border-color);
  cursor: pointer;
}

#event-map {
  width: 100%;
  height: 100%;
}

.event-map-expand {
  position: absolute;
  top: 8px;
  right: 8px;
  z-index: 500;
  background: rgba(0,0,0,0.5);
  border: none;
  color: #fff;
  padding: 6px;
  border-radius: 4px;
  cursor: pointer;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  line-height: 1;
}

.event-map-expand:hover {
  background: rgba(0,0,0,0.7);
}

.event-map-expand svg {
  width: 16px;
  height: 16px;
}

/* Fullscreen map modal */
.event-map-modal {
  position: fixed;
  inset: 0;
  z-index: 10000;
  background: rgba(0,0,0,0.95);
  display: flex;
  align-items: stretch;
  justify-content: stretch;
}

#event-map-full {
  width: 100%;
  height: 100%;
}

.event-map-modal-close {
  position: absolute;
  top: 12px;
  right: 16px;
  z-index: 10001;
  background: rgba(0,0,0,0.6);
  border: 1px solid rgba(255,255,255,0.2);
  color: #fff;
  font-size: 1.5rem;
  cursor: pointer;
  padding: 4px 12px;
  border-radius: 4px;
  line-height: 1;
}

.event-map-modal-close:hover {
  background: rgba(0,0,0,0.8);
}

/* Map pin marker */
.event-map-pin {
  background: none !important;
  border: none !important;
}

/* Coordinates row below map */
.event-coords {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-top: 6px;
  font-family: monospace;
  font-size: 0.85rem;
  opacity: 0.6;
  cursor: pointer;
  transition: opacity 0.15s;
}
.event-coords:hover {
  opacity: 1;
}
.event-coords-icon {
  flex-shrink: 0;
  width: 14px;
  height: 14px;
  display: inline-flex;
  align-items: center;
}
.event-coords-icon svg {
  width: 14px;
  height: 14px;
}
.event-coords-toast {
  position: fixed;
  bottom: 20px;
  left: 50%;
  transform: translateX(-50%);
  background: var(--accent);
  color: #000;
  padding: 8px 16px;
  border-radius: 4px;
  font-size: 0.85rem;
  z-index: 9999;
  pointer-events: none;
  animation: fadeInOut 1.5s ease forwards;
}
@keyframes fadeInOut {
  0% { opacity: 0; transform: translateX(-50%) translateY(10px); }
  15% { opacity: 1; transform: translateX(-50%) translateY(0); }
  75% { opacity: 1; }
  100% { opacity: 0; }
}

/* Leaflet overrides for dark theme */
.leaflet-container {
  background: #1a1a2e;
}

.leaflet-control-zoom a {
  background: rgba(0,0,0,0.6) !important;
  color: #fff !important;
  border-color: rgba(255,255,255,0.15) !important;
}

.leaflet-control-zoom a:hover {
  background: rgba(0,0,0,0.8) !important;
}

.leaflet-tile {
  outline: none !important;
}

/* Gallery */
.event-gallery {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
  gap: 12px;
  margin-bottom: 30px;
}

.event-gallery-item {
  border-radius: 6px;
  overflow: hidden;
  cursor: pointer;
  aspect-ratio: 4/3;
  background: rgba(128,128,128,0.1);
}

.event-gallery-item img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  transition: transform 0.2s;
}

.event-gallery-item:hover img {
  transform: scale(1.05);
}

@media (max-width: 480px) {
  .event-gallery {
    grid-template-columns: 1fr;
  }
}

/* Lightbox */
.lightbox {
  position: fixed;
  inset: 0;
  z-index: 9999;
  background: rgba(0,0,0,0.92);
  display: flex;
  align-items: center;
  justify-content: center;
}

.lightbox img {
  max-width: 90vw;
  max-height: 90vh;
  object-fit: contain;
  border-radius: 4px;
}

.lightbox-close {
  position: absolute;
  top: 16px;
  right: 20px;
  background: none;
  border: none;
  color: #fff;
  font-size: 2rem;
  cursor: pointer;
  line-height: 1;
  padding: 4px 10px;
}

.lightbox-prev,
.lightbox-next {
  position: absolute;
  top: 50%;
  transform: translateY(-50%);
  background: rgba(255,255,255,0.12);
  border: none;
  color: #fff;
  font-size: 2rem;
  cursor: pointer;
  padding: 12px 16px;
  border-radius: 4px;
}

.lightbox-prev { left: 16px; }
.lightbox-next { right: 16px; }
.lightbox-prev:hover,
.lightbox-next:hover { background: rgba(255,255,255,0.25); }

/* Stats bar */
.event-stats-bar {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 10px;
  padding: 12px 16px;
  background: var(--accent-alpha-20);
  border-radius: 6px;
  margin-bottom: 24px;
  font-size: 0.9rem;
}

.event-stat { color: var(--color); }
.event-stat-num { font-weight: 700; color: var(--accent); }
.event-stat-sep { opacity: 0.3; }

/* Feedback / Like button */
.feedback-section {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-bottom: 30px;
}

.like-button {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 8px 18px;
  border: 1px solid var(--border-color);
  border-radius: 6px;
  background: transparent;
  color: var(--color);
  cursor: pointer;
  font-size: 1rem;
  font-family: inherit;
  transition: all 0.15s;
}

.like-button svg {
  width: 16px;
  height: 16px;
}

.like-button:hover:not(:disabled) {
  border-color: var(--accent);
  color: var(--accent);
}

.like-button.liked {
  border-color: var(--accent);
  color: var(--accent);
}

.like-button:disabled {
  opacity: 0.4;
  cursor: default;
}

.like-count {
  font-size: 0.9rem;
  color: var(--accent-alpha-70);
}

.like-hint {
  font-size: 0.8rem;
  opacity: 0.4;
  font-style: italic;
}

/* Sections */
.event-section {
  margin-bottom: 30px;
}

.event-section h2 {
  font-size: 1.2rem;
  font-weight: 600;
  margin: 0 0 12px 0;
  color: var(--accent);
  border-bottom: 1px dashed var(--border-color);
  padding-bottom: 8px;
}

/* Contributor blocks (approved visitor submissions) */
.event-contributor-title {
  font-size: 1rem;
  font-weight: 600;
  margin: 0 0 8px 0;
  color: var(--accent);
  opacity: 0.85;
}

.event-contributor-desc {
  margin: 0 0 8px 0;
  font-size: 0.9rem;
  opacity: 0.75;
}

/* Contribute media CTA */
.event-contribute {
  border: 1px dashed var(--border-color);
  border-radius: 8px;
  padding: 16px;
  margin-bottom: 24px;
  background: var(--accent-alpha-20);
}

.event-contribute-btn {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  padding: 10px 16px;
  background: var(--accent);
  color: var(--background);
  border: none;
  border-radius: 6px;
  cursor: pointer;
  font-weight: 600;
  font-size: 0.95rem;
}

.event-contribute-btn:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.event-contribute-help {
  margin-top: 8px;
  font-size: 0.85rem;
  opacity: 0.75;
}

.event-contribute-status {
  margin-top: 12px;
  font-size: 0.9rem;
  padding: 8px 12px;
  background: var(--background);
  border-radius: 4px;
  border: 1px solid var(--border-color);
}

.event-contribute-queue {
  margin-top: 12px;
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.event-contribute-summary {
  font-size: 0.8rem;
  opacity: 0.7;
  margin-bottom: 4px;
}

.event-contribute-item {
  display: grid;
  grid-template-columns: 1fr auto;
  gap: 4px 12px;
  padding: 8px 10px;
  background: var(--background);
  border: 1px solid var(--border-color);
  border-radius: 4px;
  font-size: 0.85rem;
  align-items: center;
}

.event-contribute-item-name {
  font-weight: 600;
  word-break: break-all;
}

.event-contribute-item-status {
  grid-column: 1;
  opacity: 0.75;
  font-size: 0.8rem;
}

.event-contribute-item-actions {
  grid-column: 2;
  grid-row: 1 / span 2;
  display: flex;
  gap: 6px;
  align-self: center;
}

.event-contribute-mini {
  background: transparent;
  color: var(--color);
  border: 1px solid var(--border-color);
  border-radius: 3px;
  padding: 4px 8px;
  font-size: 0.75rem;
  cursor: pointer;
  opacity: 0.8;
}
.event-contribute-mini:hover {
  opacity: 1;
  border-color: var(--accent);
}

.event-body {
  color: var(--color);
  line-height: 1.7;
  font-size: 1rem;
  opacity: 0.85;
}

.event-body p { margin: 0 0 1em 0; }

.event-agenda-content {
  padding-left: 16px;
  border-left: 3px solid var(--accent);
}

/* Links */
.event-links-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.event-link-card {
  padding: 12px 16px;
  background: rgba(128,128,128,0.06);
  border-radius: 6px;
  border: 1px solid var(--border-color);
}

.event-link-url {
  color: var(--accent);
  text-decoration: none;
  font-weight: 500;
}

.event-link-url:hover {
  text-decoration: underline;
}

.event-link-domain {
  font-size: 0.8rem;
  opacity: 0.4;
  margin-top: 2px;
}

.event-link-note {
  font-size: 0.9rem;
  opacity: 0.6;
  margin-top: 4px;
}

/* Updates */
.event-update-card {
  padding: 16px;
  background: rgba(128,128,128,0.06);
  border-radius: 6px;
  border-left: 3px solid var(--accent);
  margin-bottom: 12px;
}

.event-update-title {
  font-weight: 600;
  font-size: 1.1rem;
  color: var(--color);
  margin-bottom: 4px;
}

.event-update-meta {
  font-size: 0.85rem;
  opacity: 0.5;
  margin-bottom: 8px;
}

.event-update-body {
  color: var(--color);
  opacity: 0.85;
  line-height: 1.6;
}

.event-update-stats {
  margin-top: 8px;
  font-size: 0.8rem;
  opacity: 0.4;
}

/* Comments */
.event-comment-card {
  padding: 12px 0;
  border-bottom: 1px solid var(--border-color);
}

.event-comment-card:last-child {
  border-bottom: none;
}

.event-comment-author {
  font-weight: 600;
  color: var(--accent);
  margin-bottom: 4px;
  display: flex;
  align-items: baseline;
  gap: 8px;
}

.event-comment-time {
  font-weight: 400;
  font-size: 0.8rem;
  opacity: 0.4;
  color: var(--color);
}

.event-comment-text {
  color: var(--color);
  opacity: 0.85;
  line-height: 1.5;
  white-space: pre-wrap;
  word-wrap: break-word;
}

/* Comment compose form (NOSTR-signed) */
.event-comment-compose {
  margin-top: 16px;
  padding: 16px;
  background: var(--accent-alpha-10, rgba(255,255,255,0.03));
  border: 1px solid var(--border-color);
  border-radius: 8px;
}

.event-comment-compose textarea {
  width: 100%;
  min-height: 80px;
  padding: 10px;
  background: var(--background);
  color: var(--color);
  border: 1px solid var(--border-color);
  border-radius: 4px;
  font-family: inherit;
  font-size: 0.95rem;
  resize: vertical;
  box-sizing: border-box;
}

.event-comment-compose-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-top: 10px;
}

.event-comment-compose-hint {
  font-size: 0.85rem;
  opacity: 0.6;
  color: var(--color);
}

.event-comment-compose button {
  padding: 8px 18px;
  background: var(--accent);
  color: var(--background);
  border: 0;
  border-radius: 4px;
  font-family: inherit;
  font-size: 0.95rem;
  cursor: pointer;
}

.event-comment-compose button:disabled {
  opacity: 0.4;
  cursor: default;
}

.event-comments-disabled {
  margin-top: 12px;
  font-size: 0.9rem;
  opacity: 0.5;
  font-style: italic;
}

.event-comment-delete {
  margin-left: auto;
  background: transparent;
  border: 0;
  color: var(--color);
  opacity: 0.4;
  font-size: 1.1rem;
  cursor: pointer;
  padding: 0 4px;
  line-height: 1;
}

.event-comment-delete:hover {
  opacity: 1;
  color: #e25555;
}

/* Contacts badges */
.event-contacts {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}

.event-contact-badge {
  display: inline-block;
  padding: 4px 12px;
  background: var(--accent-alpha-20);
  border-radius: 4px;
  font-size: 0.9rem;
  color: var(--accent);
  font-weight: 500;
}
''';

  static const String _defaultFilesIndexHtml = r'''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{{TITLE}} - Files</title>
  <link rel="stylesheet" href="/styles.css">
  <link rel="stylesheet" href="styles.css">
</head>
<body>
  <header class="header">
    <div class="container">
      <div class="header-content">
        <div>
          <h1 class="header-title">{{COLLECTION_NAME}}</h1>
          <p class="header-subtitle">{{COLLECTION_DESCRIPTION}}</p>
        </div>
        <nav class="nav">
          <span class="badge">Files</span>
        </nav>
      </div>
    </div>
  </header>

  <main class="main">
    <div class="container">
      <div class="files-header">
        <div class="search-container">
          <input type="text" class="input search-input" placeholder="Search files..." id="search">
        </div>
        <div class="files-stats">
          <span class="stat"><strong id="file-count">0</strong> files</span>
          <span class="stat"><strong id="dir-count">0</strong> folders</span>
          <span class="stat"><strong id="total-size">0 B</strong> total</span>
        </div>
      </div>

      <div class="breadcrumb" id="breadcrumb">
        <span class="breadcrumb-item active">Root</span>
      </div>

      <div class="files-container">
        <div class="file-tree" id="tree">
          <!-- Tree view will be populated by JavaScript -->
        </div>

        <div class="file-list-container">
          <div class="file-list" id="files">
            {{CONTENT}}
          </div>
        </div>
      </div>
    </div>
  </main>

  <footer class="footer">
    <div class="container">
      <p>Generated on {{GENERATED_DATE}}</p>
    </div>
  </footer>

  <script>
    window.GEOGRAM_DATA = {{DATA_JSON}};
    {{SCRIPTS}}
  </script>
  <script>
    // Format file size
    function formatSize(bytes) {
      if (bytes === 0) return '0 B';
      if (bytes < 1024) return bytes + ' B';
      if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
      if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
      return (bytes / (1024 * 1024 * 1024)).toFixed(1) + ' GB';
    }

    // Get file icon based on extension
    function getFileIcon(filename) {
      const ext = filename.split('.').pop().toLowerCase();
      const icons = {
        'pdf': '📕', 'doc': '📘', 'docx': '📘', 'txt': '📄',
        'jpg': '🖼️', 'jpeg': '🖼️', 'png': '🖼️', 'gif': '🖼️', 'svg': '🖼️',
        'mp3': '🎵', 'wav': '🎵', 'ogg': '🎵',
        'mp4': '🎬', 'avi': '🎬', 'mkv': '🎬', 'mov': '🎬',
        'zip': '📦', 'rar': '📦', 'tar': '📦', 'gz': '📦',
        'js': '📜', 'ts': '📜', 'py': '📜', 'rb': '📜', 'go': '📜',
        'html': '🌐', 'css': '🎨', 'json': '📋', 'xml': '📋'
      };
      return icons[ext] || '📄';
    }

    // Render file list
    function renderFiles() {
      const container = document.getElementById('files');
      const data = window.GEOGRAM_DATA || { files: [] };
      const files = data.files || [];

      if (files.length === 0) return;

      // Calculate stats
      let fileCount = 0, dirCount = 0, totalSize = 0;
      files.forEach(f => {
        if (f.type === 'directory') dirCount++;
        else { fileCount++; totalSize += f.size || 0; }
      });

      document.getElementById('file-count').textContent = fileCount;
      document.getElementById('dir-count').textContent = dirCount;
      document.getElementById('total-size').textContent = formatSize(totalSize);

      container.innerHTML = files.map(file => `
        <div class="file-item" data-name="${file.name.toLowerCase()}" data-type="${file.type}">
          <span class="file-icon">${file.type === 'directory' ? '📁' : getFileIcon(file.name)}</span>
          <div class="file-info">
            <span class="file-name">${file.name}</span>
            ${file.mimeType ? `<span class="file-type">${file.mimeType}</span>` : ''}
          </div>
          <span class="file-size">${file.size ? formatSize(file.size) : ''}</span>
          ${file.hashes && file.hashes.sha1 ? `<span class="file-hash" title="${file.hashes.sha1}">${file.hashes.sha1.substring(0, 8)}</span>` : ''}
        </div>
      `).join('');
    }

    // Search functionality
    document.getElementById('search').addEventListener('input', function(e) {
      const query = e.target.value.toLowerCase();
      const items = document.querySelectorAll('.file-item');
      items.forEach(item => {
        const name = item.dataset.name;
        item.style.display = name.includes(query) ? '' : 'none';
      });
    });

    renderFiles();
  </script>
</body>
</html>
''';

  static const String _defaultFilesStylesCss = r'''
/* Files App - Theme Overrides */

/* Files Header */
.files-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: var(--spacing-md);
  gap: var(--spacing-md);
}

@media (max-width: 768px) {
  .files-header {
    flex-direction: column;
    align-items: stretch;
  }
}

.files-stats {
  display: flex;
  gap: var(--spacing-lg);
  color: var(--color-text-muted);
  font-size: var(--font-size-sm);
}

.files-stats strong {
  color: var(--color-text);
}

/* Breadcrumb */
.breadcrumb {
  display: flex;
  align-items: center;
  gap: var(--spacing-xs);
  padding: var(--spacing-sm) var(--spacing-md);
  background-color: var(--color-bg-secondary);
  border-radius: var(--border-radius);
  margin-bottom: var(--spacing-md);
  font-size: var(--font-size-sm);
  overflow-x: auto;
}

.breadcrumb-item {
  color: var(--color-text-secondary);
  cursor: pointer;
  white-space: nowrap;
}

.breadcrumb-item:hover {
  color: var(--color-accent);
}

.breadcrumb-item.active {
  color: var(--color-text);
  font-weight: 500;
}

.breadcrumb-item:not(:last-child)::after {
  content: '/';
  margin-left: var(--spacing-xs);
  color: var(--color-text-muted);
}

/* Files Container */
.files-container {
  display: grid;
  grid-template-columns: 250px 1fr;
  gap: var(--spacing-lg);
}

@media (max-width: 768px) {
  .files-container {
    grid-template-columns: 1fr;
  }
  .file-tree {
    display: none;
  }
}

/* File Tree */
.file-tree {
  background-color: var(--color-bg-secondary);
  border-radius: var(--border-radius);
  padding: var(--spacing-md);
  max-height: 70vh;
  overflow-y: auto;
}

.tree-node {
  padding: var(--spacing-xs) 0;
}

.tree-node-header {
  display: flex;
  align-items: center;
  gap: var(--spacing-xs);
  padding: var(--spacing-xs) var(--spacing-sm);
  border-radius: var(--border-radius-sm);
  cursor: pointer;
  transition: background-color var(--transition-fast);
}

.tree-node-header:hover {
  background-color: var(--color-bg-tertiary);
}

.tree-node-header.selected {
  background-color: var(--color-accent);
  color: white;
}

.tree-toggle {
  width: 16px;
  text-align: center;
  font-size: var(--font-size-xs);
}

.tree-icon {
  font-size: var(--font-size-base);
}

.tree-name {
  font-size: var(--font-size-sm);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.tree-children {
  padding-left: var(--spacing-md);
  margin-left: var(--spacing-sm);
  border-left: 1px solid var(--color-border-light);
}

/* File List Container */
.file-list-container {
  background-color: var(--color-bg);
  border: 1px solid var(--color-border-light);
  border-radius: var(--border-radius);
  overflow: hidden;
}

/* File List */
.file-list {
  max-height: 70vh;
  overflow-y: auto;
}

/* File Item */
.file-item {
  display: flex;
  align-items: center;
  gap: var(--spacing-md);
  padding: var(--spacing-md);
  border-bottom: 1px solid var(--color-border-light);
  transition: background-color var(--transition-fast);
  cursor: pointer;
}

.file-item:last-child {
  border-bottom: none;
}

.file-item:hover {
  background-color: var(--color-bg-secondary);
}

.file-item[data-type="directory"] {
  font-weight: 500;
}

/* File Icon */
.file-icon {
  font-size: var(--font-size-xl);
  width: 32px;
  text-align: center;
  flex-shrink: 0;
}

/* File Info */
.file-info {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.file-name {
  color: var(--color-text);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.file-type {
  font-size: var(--font-size-xs);
  color: var(--color-text-muted);
}

/* File Size */
.file-size {
  font-size: var(--font-size-sm);
  color: var(--color-text-muted);
  white-space: nowrap;
  min-width: 70px;
  text-align: right;
}

/* File Hash */
.file-hash {
  font-family: var(--font-family-mono);
  font-size: var(--font-size-xs);
  color: var(--color-text-muted);
  background-color: var(--color-bg-secondary);
  padding: 2px 6px;
  border-radius: var(--border-radius-sm);
  cursor: help;
}

/* Empty State */
.files-empty {
  padding: var(--spacing-2xl);
  text-align: center;
  color: var(--color-text-muted);
}

.files-empty-icon {
  font-size: 3rem;
  margin-bottom: var(--spacing-md);
  opacity: 0.5;
}

/* Selected File */
.file-item.selected {
  background-color: var(--color-bg-secondary);
  border-left: 3px solid var(--color-accent);
}
''';

  static const String _defaultForumIndexHtml = r'''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{{TITLE}} - Forum</title>
  <link rel="stylesheet" href="/styles.css">
  <link rel="stylesheet" href="styles.css">
</head>
<body>
  <header class="header">
    <div class="container">
      <div class="header-content">
        <div>
          <h1 class="header-title">{{COLLECTION_NAME}}</h1>
          <p class="header-subtitle">{{COLLECTION_DESCRIPTION}}</p>
        </div>
        <nav class="nav">
          <span class="badge">Forum</span>
        </nav>
      </div>
    </div>
  </header>

  <main class="main">
    <div class="container">
      <div class="forum-header">
        <div class="search-container">
          <input type="text" class="input search-input" placeholder="Search threads..." id="search">
        </div>
        <div class="forum-stats">
          <span class="stat"><strong id="thread-count">0</strong> threads</span>
          <span class="stat"><strong id="post-count">0</strong> posts</span>
        </div>
      </div>

      <div class="categories-list" id="categories">
        <!-- Categories will be populated by JavaScript or content -->
      </div>

      <div class="threads-list" id="threads">
        {{CONTENT}}
      </div>
    </div>
  </main>

  <footer class="footer">
    <div class="container">
      <p>Generated on {{GENERATED_DATE}}</p>
    </div>
  </footer>

  <script>
    window.GEOGRAM_DATA = {{DATA_JSON}};
    {{SCRIPTS}}
  </script>
  <script>
    // Search functionality
    document.getElementById('search').addEventListener('input', function(e) {
      const query = e.target.value.toLowerCase();
      const threads = document.querySelectorAll('.thread-item');
      threads.forEach(thread => {
        const text = thread.textContent.toLowerCase();
        thread.style.display = text.includes(query) ? '' : 'none';
      });
    });

    // Update stats
    const data = window.GEOGRAM_DATA || {};
    document.getElementById('thread-count').textContent = data.threadCount || document.querySelectorAll('.thread-item').length;
    document.getElementById('post-count').textContent = data.postCount || 0;
  </script>
</body>
</html>
''';

  static const String _defaultForumStylesCss = r'''
/* Forum App - Theme Overrides */

/* Forum Header */
.forum-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: var(--spacing-lg);
  gap: var(--spacing-md);
}

@media (max-width: 640px) {
  .forum-header {
    flex-direction: column;
    align-items: stretch;
  }
}

.forum-stats {
  display: flex;
  gap: var(--spacing-lg);
  color: var(--color-text-muted);
  font-size: var(--font-size-sm);
}

.stat strong {
  color: var(--color-text);
}

/* Categories */
.categories-list {
  display: flex;
  flex-wrap: wrap;
  gap: var(--spacing-sm);
  margin-bottom: var(--spacing-lg);
}

.category-tag {
  padding: var(--spacing-sm) var(--spacing-md);
  background-color: var(--color-bg-secondary);
  border-radius: var(--border-radius);
  font-size: var(--font-size-sm);
  color: var(--color-text-secondary);
  cursor: pointer;
  transition: all var(--transition-fast);
}

.category-tag:hover {
  background-color: var(--color-bg-tertiary);
  color: var(--color-text);
}

.category-tag.active {
  background-color: var(--color-accent);
  color: white;
}

/* Threads List */
.threads-list {
  background-color: var(--color-bg);
  border: 1px solid var(--color-border-light);
  border-radius: var(--border-radius);
  overflow: hidden;
}

/* Thread Item */
.thread-item {
  display: flex;
  gap: var(--spacing-md);
  padding: var(--spacing-lg);
  border-bottom: 1px solid var(--color-border-light);
  transition: background-color var(--transition-fast);
}

.thread-item:last-child {
  border-bottom: none;
}

.thread-item:hover {
  background-color: var(--color-bg-secondary);
}

.thread-avatar {
  flex-shrink: 0;
}

.thread-content {
  flex: 1;
  min-width: 0;
}

.thread-title {
  font-size: var(--font-size-lg);
  font-weight: 600;
  margin-bottom: var(--spacing-xs);
  color: var(--color-text);
}

.thread-title a {
  color: inherit;
}

.thread-title a:hover {
  color: var(--color-accent);
}

.thread-meta {
  display: flex;
  flex-wrap: wrap;
  gap: var(--spacing-md);
  font-size: var(--font-size-sm);
  color: var(--color-text-muted);
}

.thread-author {
  color: var(--color-text-secondary);
}

.thread-excerpt {
  margin-top: var(--spacing-sm);
  color: var(--color-text-secondary);
  font-size: var(--font-size-sm);
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.thread-stats {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: var(--spacing-xs);
  flex-shrink: 0;
  text-align: right;
}

.thread-replies {
  font-size: var(--font-size-xl);
  font-weight: 600;
  color: var(--color-text);
}

.thread-replies-label {
  font-size: var(--font-size-xs);
  color: var(--color-text-muted);
}

.thread-last-activity {
  font-size: var(--font-size-xs);
  color: var(--color-text-muted);
}

/* Thread Tags */
.thread-tags {
  display: flex;
  gap: var(--spacing-xs);
  margin-top: var(--spacing-sm);
}

.thread-tag {
  font-size: var(--font-size-xs);
  padding: 2px 8px;
  background-color: var(--color-bg-tertiary);
  border-radius: var(--border-radius-sm);
  color: var(--color-text-secondary);
}

/* Pinned Thread */
.thread-item.pinned {
  background-color: var(--color-bg-secondary);
  border-left: 3px solid var(--color-accent);
}

.thread-item.pinned .thread-title::before {
  content: '📌 ';
}

/* Locked Thread */
.thread-item.locked {
  opacity: 0.7;
}

.thread-item.locked .thread-title::before {
  content: '🔒 ';
}
''';

  static const String _defaultHomeIndexHtml = r'''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{{TITLE}}</title>
  <link rel="stylesheet" href="/styles.css">
  <link rel="stylesheet" href="styles.css">
</head>
<body>
  <header class="header">
    <div class="container">
      <div class="header-content">
        <div>
          <h1 class="header-title">{{COLLECTION_NAME}}</h1>
          <p class="header-subtitle">{{COLLECTION_DESCRIPTION}}</p>
        </div>
      </div>
    </div>
  </header>

  <main class="main">
    <div class="container">
      <!-- Navigation Cards -->
      <section class="home-nav">
        <a href="../blog/" class="nav-card" id="nav-blog">
          <span class="nav-card-icon">&#128221;</span>
          <span class="nav-card-title">Blog</span>
          <span class="nav-card-desc">Articles and posts</span>
        </a>
        <a href="../chat/" class="nav-card">
          <span class="nav-card-icon">&#128172;</span>
          <span class="nav-card-title">Chat</span>
          <span class="nav-card-desc">Join conversations</span>
        </a>
        <a href="../events/" class="nav-card">
          <span class="nav-card-icon">&#128197;</span>
          <span class="nav-card-title">Events</span>
          <span class="nav-card-desc">Upcoming activities</span>
        </a>
        <a href="../places/" class="nav-card">
          <span class="nav-card-icon">&#128205;</span>
          <span class="nav-card-title">Places</span>
          <span class="nav-card-desc">Locations and spots</span>
        </a>
        <a href="../files/" class="nav-card">
          <span class="nav-card-icon">&#128193;</span>
          <span class="nav-card-title">Files</span>
          <span class="nav-card-desc">Downloads and media</span>
        </a>
        <a href="../alerts/" class="nav-card">
          <span class="nav-card-icon">&#128680;</span>
          <span class="nav-card-title">Alerts</span>
          <span class="nav-card-desc">Notifications and warnings</span>
        </a>
        <a href="../download/" class="nav-card">
          <span class="nav-card-icon">&#128229;</span>
          <span class="nav-card-title">Download</span>
          <span class="nav-card-desc">Apps and AI models</span>
        </a>
      </section>

      <!-- Recent Blog Posts -->
      <section class="home-section" id="blog-section">
        <div class="section-header">
          <h2>Recent Posts</h2>
          <a href="../blog/" class="btn btn-secondary">View all</a>
        </div>
        <div class="posts-grid" id="recent-posts">
          {{RECENT_POSTS}}
        </div>
      </section>

      <!-- Upcoming Events -->
      <section class="home-section" id="events-section">
        <div class="section-header">
          <h2>Upcoming Events</h2>
          <a href="../events/" class="btn btn-secondary">View all</a>
        </div>
        <div class="events-list" id="upcoming-events">
          {{UPCOMING_EVENTS}}
        </div>
      </section>

      <!-- Places Summary -->
      <section class="home-section" id="places-section">
        <div class="section-header">
          <h2>Places</h2>
          <a href="../places/" class="btn btn-secondary">Browse all</a>
        </div>
        <div class="places-summary">
          <p class="places-count">{{PLACES_COUNT}} public places available</p>
          {{FEATURED_PLACES}}
        </div>
      </section>

      <!-- Chat Rooms -->
      <section class="home-section" id="chat-section">
        <div class="section-header">
          <h2>Chat Rooms</h2>
          <a href="../chat/" class="btn btn-secondary">Join a room</a>
        </div>
        <div class="chat-rooms-list" id="chat-rooms">
          {{CHAT_ROOMS}}
        </div>
      </section>
    </div>
  </main>

  <footer class="footer">
    <div class="container">
      <p>Generated on {{GENERATED_DATE}}</p>
    </div>
  </footer>

  <script>
    window.GEOGRAM_DATA = {{DATA_JSON}};
    {{SCRIPTS}}
  </script>
  <script>
    // Hide empty sections
    document.addEventListener('DOMContentLoaded', function() {
      const data = window.GEOGRAM_DATA || {};

      // Hide blog section and nav card if no posts
      if (!data.recentPosts || data.recentPosts.length === 0) {
        const blogNav = document.getElementById('nav-blog');
        if (blogNav) blogNav.style.display = 'none';
        const blogSection = document.getElementById('blog-section');
        if (blogSection) blogSection.style.display = 'none';
      }

      // Hide events section if no events
      if (!data.upcomingEvents || data.upcomingEvents.length === 0) {
        const eventsSection = document.getElementById('events-section');
        if (eventsSection) eventsSection.style.display = 'none';
      }

      // Hide places section if no places
      if (!data.placesCount || data.placesCount === 0) {
        const placesSection = document.getElementById('places-section');
        if (placesSection) placesSection.style.display = 'none';
      }

      // Hide chat section if no rooms
      if (!data.chatRooms || data.chatRooms.length === 0) {
        const chatSection = document.getElementById('chat-section');
        if (chatSection) chatSection.style.display = 'none';
      }
    });
  </script>
</body>
</html>
''';

  static const String _defaultHomeStylesCss = r'''
/* Home Page Styles */

/* Navigation Cards Grid */
.home-nav {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
  gap: var(--spacing-md);
  margin-bottom: var(--spacing-2xl);
}

.nav-card {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: var(--spacing-lg);
  background-color: var(--color-bg-secondary);
  border: 1px solid var(--color-border-light);
  border-radius: var(--border-radius-lg);
  text-decoration: none;
  color: var(--color-text);
  transition: all var(--transition-normal);
  text-align: center;
}

.nav-card:hover {
  background-color: var(--color-bg-tertiary);
  border-color: var(--color-accent);
  transform: translateY(-2px);
  box-shadow: var(--shadow-md);
  text-decoration: none;
}

.nav-card-icon {
  font-size: 2rem;
  margin-bottom: var(--spacing-sm);
}

.nav-card-title {
  font-size: var(--font-size-lg);
  font-weight: 600;
  margin-bottom: var(--spacing-xs);
}

.nav-card-desc {
  font-size: var(--font-size-sm);
  color: var(--color-text-muted);
}

/* Home Sections */
.home-section {
  margin-bottom: var(--spacing-2xl);
  padding: var(--spacing-lg);
  background-color: var(--color-bg);
  border: 1px solid var(--color-border-light);
  border-radius: var(--border-radius);
}

.section-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: var(--spacing-lg);
  padding-bottom: var(--spacing-md);
  border-bottom: 1px solid var(--color-border-light);
}

.section-header h2 {
  margin: 0;
  font-size: var(--font-size-xl);
}

/* Posts Grid */
.posts-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: var(--spacing-md);
}

.post-card {
  padding: var(--spacing-md);
  background-color: var(--color-bg-secondary);
  border-radius: var(--border-radius);
  transition: all var(--transition-fast);
}

.post-card:hover {
  background-color: var(--color-bg-tertiary);
}

.post-card-title {
  font-size: var(--font-size-base);
  font-weight: 600;
  margin-bottom: var(--spacing-sm);
  color: var(--color-text);
}

.post-card-title a {
  color: inherit;
  text-decoration: none;
}

.post-card-title a:hover {
  color: var(--color-accent);
}

.post-card-meta {
  font-size: var(--font-size-sm);
  color: var(--color-text-muted);
  margin-bottom: var(--spacing-sm);
}

.post-card-excerpt {
  font-size: var(--font-size-sm);
  color: var(--color-text-secondary);
  line-height: 1.5;
}

/* Events List */
.events-list {
  display: flex;
  flex-direction: column;
  gap: var(--spacing-md);
}

.event-item {
  display: flex;
  gap: var(--spacing-md);
  padding: var(--spacing-md);
  background-color: var(--color-bg-secondary);
  border-radius: var(--border-radius);
  transition: background-color var(--transition-fast);
}

.event-item:hover {
  background-color: var(--color-bg-tertiary);
}

.event-date {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  min-width: 60px;
  padding: var(--spacing-sm);
  background-color: var(--color-accent);
  color: white;
  border-radius: var(--border-radius-sm);
  text-align: center;
}

.event-date-day {
  font-size: var(--font-size-xl);
  font-weight: 700;
  line-height: 1;
}

.event-date-month {
  font-size: var(--font-size-xs);
  text-transform: uppercase;
}

.event-details {
  flex: 1;
}

.event-title {
  font-size: var(--font-size-base);
  font-weight: 600;
  margin-bottom: var(--spacing-xs);
}

.event-title a {
  color: var(--color-text);
  text-decoration: none;
}

.event-title a:hover {
  color: var(--color-accent);
}

.event-info {
  font-size: var(--font-size-sm);
  color: var(--color-text-muted);
}

/* Places Summary */
.places-summary {
  text-align: center;
  padding: var(--spacing-lg);
}

.places-count {
  font-size: var(--font-size-lg);
  color: var(--color-text-secondary);
  margin-bottom: var(--spacing-md);
}

.featured-places {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
  gap: var(--spacing-md);
  margin-top: var(--spacing-md);
}

.place-card {
  padding: var(--spacing-md);
  background-color: var(--color-bg-secondary);
  border-radius: var(--border-radius);
  text-align: left;
}

.place-card-name {
  font-weight: 600;
  margin-bottom: var(--spacing-xs);
}

.place-card-type {
  font-size: var(--font-size-sm);
  color: var(--color-text-muted);
}

/* Chat Rooms List */
.chat-rooms-list {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
  gap: var(--spacing-md);
}

.chat-room-card {
  display: flex;
  align-items: center;
  gap: var(--spacing-md);
  padding: var(--spacing-md);
  background-color: var(--color-bg-secondary);
  border-radius: var(--border-radius);
  text-decoration: none;
  color: var(--color-text);
  transition: all var(--transition-fast);
}

.chat-room-card:hover {
  background-color: var(--color-bg-tertiary);
  text-decoration: none;
}

.chat-room-icon {
  width: 40px;
  height: 40px;
  display: flex;
  align-items: center;
  justify-content: center;
  background-color: var(--color-accent);
  color: white;
  border-radius: 50%;
  font-size: var(--font-size-lg);
}

.chat-room-info {
  flex: 1;
}

.chat-room-name {
  font-weight: 600;
  margin-bottom: var(--spacing-xs);
}

.chat-room-members {
  font-size: var(--font-size-sm);
  color: var(--color-text-muted);
}

/* Empty States */
.empty-message {
  text-align: center;
  padding: var(--spacing-lg);
  color: var(--color-text-muted);
  font-style: italic;
}

/* Responsive */
@media (max-width: 768px) {
  .home-nav {
    grid-template-columns: repeat(2, 1fr);
  }

  .nav-card {
    padding: var(--spacing-md);
  }

  .nav-card-icon {
    font-size: 1.5rem;
  }

  .nav-card-title {
    font-size: var(--font-size-base);
  }

  .section-header {
    flex-direction: column;
    align-items: flex-start;
    gap: var(--spacing-sm);
  }

  .posts-grid {
    grid-template-columns: 1fr;
  }

  .event-item {
    flex-direction: column;
  }

  .event-date {
    flex-direction: row;
    gap: var(--spacing-sm);
    min-width: auto;
    padding: var(--spacing-sm) var(--spacing-md);
  }
}
''';

  static const String _defaultMeetIndexHtml = r'''
<!DOCTYPE html>
<html lang="en" class="meet-page">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
  <title>{{TITLE}}</title>
  <style>{{GLOBAL_STYLES}}</style>
  <style>{{APP_STYLES}}</style>
  {{NOSTR_STYLES}}
</head>
<body>
<div class="container">
  <header class="header">
    <div class="header__inner">
      <div class="header__logo">
        <div class="logo">{{LOGO_TEXT}}</div>
      </div>
      {{NOSTR_HEADER}}
    </div>
  </header>

  <main class="main">
    <div class="meeting-shell">
      <section class="meeting-card">
        <div class="meeting-description"{{ROOM_DESCRIPTION_ATTR}}>{{ROOM_DESCRIPTION}}</div>
        <div class="meeting-subtitle">{{ROOM_SUBTITLE}}</div>
        <div id="status">{{STATUS_TEXT}}</div>
        <div id="meeting-note" class="meeting-note"></div>
        <div id="nostr-gate-msg">Use the identity button above to authenticate before joining the meeting.</div>
        <div id="join-form">
          <label for="nickname" class="nickname-label">Enter your name to join</label>
          <input id="nickname" type="text" placeholder="Your name" maxlength="20" autofocus>
          <div class="button-row">
            <button id="btn-join" type="button">Join</button>
          </div>
        </div>
      </section>

      <section id="call-ui">
        <div class="meeting-layout">
          <div class="stage">
            <div class="stage-panel" id="screen-share-shell">
              <div class="stage-label">
                <div id="screen-share-label">Shared screen</div>
                <button id="btn-screen-fullscreen" type="button">Full screen</button>
              </div>
              <video id="screen-share-video" autoplay playsinline muted></video>
              <div id="screen-share-placeholder">No screen is being shared right now.</div>
            </div>

            <div id="archive-assets-shell">
              <div class="sidebar-title" id="archive-assets-title">Recordings</div>
              <div id="archive-assets"></div>
            </div>

            <div class="stage-panel">
              <div class="meeting-controls">
                <button id="btn-mute" type="button" style="display:none;">Mute</button>
                <button id="btn-request-speaker" type="button" style="display:none;">Request Mic</button>
                <button id="btn-leave" type="button">Leave</button>
              </div>
            </div>
          </div>

          <aside class="sidebar-panel">
            <div class="sidebar-title">People</div>
            <ul id="participants"></ul>

            <div id="chat-shell">
              <div class="sidebar-title">Chat</div>
              <div id="chat-messages"></div>
              <div class="chat-input-row">
                <input id="chat-input" type="text" placeholder="Type a message..." maxlength="500">
                <button id="btn-send-chat" type="button">Send</button>
              </div>
            </div>
          </aside>
        </div>
      </section>
    </div>
  </main>

  <footer class="footer">
    <div class="footer__inner">
      <div class="copyright">
        <span>powered by geogram</span>
      </div>
    </div>
  </footer>
</div>

<script>
  window.GEOGRAM_MEETING = {{DATA_JSON}};
  {{SCRIPTS}}
</script>
</body>
</html>
''';

  static const String _defaultMeetListingHtml = r'''
<!DOCTYPE html>
<html lang="en" class="meet-page">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
  <title>{{TITLE}}</title>
  <style>{{GLOBAL_STYLES}}</style>
  <style>{{APP_STYLES}}</style>
  {{NOSTR_STYLES}}
</head>
<body>
<div class="container">
  <header class="header">
    <div class="header__inner">
      <div class="header__logo">
        <div class="logo">{{LOGO_TEXT}}</div>
      </div>
      {{NOSTR_HEADER}}
    </div>
    <nav class="menu">
      <ul class="menu__inner">
        {{MENU_ITEMS}}
      </ul>
    </nav>
  </header>

  <main class="main">
    <div class="meeting-shell">
      <section class="meeting-card">
        <div class="meeting-subtitle">Browse meetings hosted on this station</div>
        <input id="listing-search" class="listing-search" type="text" placeholder="Search meetings..." autofocus>
        <div id="meeting-list" class="meeting-list"></div>
        <div id="listing-hint" class="listing-hint" style="display:none"></div>
      </section>
    </div>
  </main>

  <footer class="footer">
    <div class="footer__inner">
      <div class="copyright">
        <span>powered by geogram</span>
      </div>
    </div>
  </footer>
</div>

<script>
  window.GEOGRAM_MEETINGS = {{DATA_JSON}};
  {{SCRIPTS}}

  'use strict';
  (function() {
    const data = window.GEOGRAM_MEETINGS || {};
    const listEl = document.getElementById('meeting-list');
    const hintEl = document.getElementById('listing-hint');
    const searchEl = document.getElementById('listing-search');

    const allItems = [];
    if (data.active) allItems.push(data.active);
    if (data.scheduled) data.scheduled.forEach(function(s) { allItems.push(s); });
    if (data.meetings) data.meetings.forEach(function(m) { allItems.push(m); });

    if (!data.authenticated) {
      hintEl.textContent = 'Connect with Nostr to see private meetings';
      hintEl.style.display = '';
    }

    function formatDate(iso) {
      if (!iso) return '';
      var d = new Date(iso);
      return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
    }

    function renderBadge(state) {
      if (state === 'active') return '<span class="meeting-badge meeting-badge--live">LIVE</span>';
      if (state === 'scheduled') return '<span class="meeting-badge meeting-badge--scheduled">Scheduled</span>';
      return '';
    }

    function renderTags(tags) {
      if (!tags || tags.length === 0) return '';
      return '<div class="meeting-tags">' +
        tags.map(function(t) { return '<span class="meeting-tag">' + esc(t) + '</span>'; }).join('') +
        '</div>';
    }

    function esc(s) {
      var el = document.createElement('span');
      el.textContent = s || '';
      return el.innerHTML;
    }

    function renderItem(item) {
      var meta = [];
      if (item.hostCallsign) meta.push('Host: ' + esc(item.hostCallsign));
      if (item.state === 'active' || item.state === 'scheduled') {
        if (item.participantCount != null) meta.push(item.participantCount + ' participant' + (item.participantCount === 1 ? '' : 's'));
        if (item.scheduledAt) meta.push(formatDate(item.scheduledAt));
      } else {
        if (item.startedAt) {
          var range = formatDate(item.startedAt);
          if (item.endedAt) range += ' — ' + formatDate(item.endedAt);
          meta.push(range);
        }
        var counts = [];
        if (item.participantCount) counts.push(item.participantCount + ' participant' + (item.participantCount === 1 ? '' : 's'));
        if (item.messageCount) counts.push(item.messageCount + ' message' + (item.messageCount === 1 ? '' : 's'));
        if (item.fileCount) counts.push(item.fileCount + ' file' + (item.fileCount === 1 ? '' : 's'));
        if (item.recordingCount) counts.push(item.recordingCount + ' recording' + (item.recordingCount === 1 ? '' : 's'));
        if (counts.length) meta.push(counts.join(' · '));
      }

      return '<a class="meeting-list-item" href="' + esc(item.code) + '">' +
        '<div class="meeting-list-header">' +
          '<span class="meeting-list-title">' + esc(item.roomName || item.code) + '</span>' +
          renderBadge(item.state) +
        '</div>' +
        '<div class="meeting-list-meta">' + meta.join(' · ') + '</div>' +
        renderTags(item.tags) +
      '</a>';
    }

    function render(filter) {
      var filtered = allItems;
      if (filter) {
        var q = filter.toLowerCase();
        filtered = allItems.filter(function(item) {
          var haystack = (item.roomName || '') + ' ' + (item.hostCallsign || '') + ' ' + (item.tags || []).join(' ');
          return haystack.toLowerCase().indexOf(q) !== -1;
        });
      }
      if (filtered.length === 0) {
        listEl.innerHTML = '<div class="listing-empty">' + (allItems.length === 0 ? 'No meetings yet' : 'No matches') + '</div>';
      } else {
        listEl.innerHTML = filtered.map(renderItem).join('');
      }
    }

    render('');
    searchEl.addEventListener('input', function() { render(searchEl.value); });

    document.addEventListener('nostr-connected', function() {
      if (!data.authenticated) {
        window.location.reload();
      }
    });
  })();
</script>
</body>
</html>
''';

  static const String _defaultMeetStylesCss = r'''
/* Meetings page - extends global Terminimal theme */

.meet-page .container {
  max-width: 1100px;
}

.meeting-shell {
  display: flex;
  flex-direction: column;
  gap: 18px;
}

.meeting-card,
.stage-panel,
.sidebar-panel {
  border: 1px solid var(--border-color);
  border-radius: 14px;
  padding: 18px;
  background: rgba(0, 0, 0, 0.08);
}

.meeting-subtitle,
#status,
#meeting-note,
#nostr-gate-msg,
.participant-role,
.chat-meta {
  color: var(--accent-alpha-70);
}

.meeting-description {
  margin: 0 0 6px 0;
  font-size: 1.1rem;
}

#status {
  font-size: 0.95rem;
  margin-bottom: 14px;
}

#nostr-gate-msg {
  margin-bottom: 16px;
}

#meeting-note {
  margin-bottom: 12px;
}

#join-form {
  display: none;
  gap: 12px;
  flex-wrap: wrap;
  align-items: center;
}

.nickname-label {
  width: 100%;
  font-size: 0.9em;
  opacity: 0.8;
}

#join-form input,
#chat-input {
  min-width: 240px;
  flex: 1;
  border: 1px solid var(--border-color);
  border-radius: 10px;
  background: transparent;
  color: inherit;
  padding: 12px 14px;
  font: inherit;
}

.button-row,
.meeting-controls,
.chat-input-row {
  display: flex;
  gap: 10px;
  flex-wrap: wrap;
}

.volume-meter {
  display: flex;
  align-items: flex-end;
  gap: 2px;
  height: 24px;
  width: 100%;
  margin-bottom: 10px;
}
.volume-meter .bar {
  flex: 1;
  min-width: 2px;
  height: 2px;
  background: var(--accent);
  border-radius: 1px;
  opacity: 0.3;
  transition: height 80ms ease-out, opacity 80ms ease-out;
}

button {
  border: 1px solid var(--border-color);
  background: transparent;
  color: inherit;
  padding: 10px 14px;
  font: inherit;
  cursor: pointer;
  border-radius: 10px;
}

button:hover:not(:disabled) {
  border-color: var(--accent);
  color: var(--accent);
}

button:disabled {
  opacity: 0.45;
  cursor: default;
}

#btn-join,
#btn-request-speaker,
#btn-send-chat {
  border-color: var(--accent);
}

#btn-leave {
  border-color: #d90429;
  color: #d90429;
}

#btn-mute.muted,
#btn-leave:hover {
  background: #d90429;
  color: #fff;
}

#call-ui {
  display: none;
}

.meeting-layout {
  display: grid;
  grid-template-columns: minmax(0, 1.9fr) minmax(280px, 0.9fr);
  gap: 18px;
}

.stage {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.stage-label {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 10px;
}

#screen-share-shell {
  display: none;
}

#screen-share-shell.active {
  display: block;
}

#screen-share-video,
#screen-share-placeholder {
  width: 100%;
  aspect-ratio: 16 / 9;
  border-radius: 12px;
}

#screen-share-video {
  background: #000;
  object-fit: contain;
}

#screen-share-placeholder {
  border: 1px dashed var(--border-color);
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.15);
}

.sidebar-title {
  margin-bottom: 8px;
  color: var(--accent);
  font-weight: bold;
}

#participants {
  list-style: none;
  padding: 0;
  margin: 0 0 18px 0;
}

#participants li {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  padding: 9px 0;
  border-bottom: 1px solid var(--border-color);
}

#participants li:last-child {
  border-bottom: 0;
}

.participant-state {
  text-align: right;
}

#chat-shell {
  display: flex;
  flex-direction: column;
  gap: 10px;
  min-height: 320px;
}

#archive-assets-shell {
  display: none;
}

#chat-messages {
  flex: 1;
  min-height: 180px;
  max-height: 320px;
  overflow-y: auto;
  border: 1px solid var(--border-color);
  border-radius: 12px;
  padding: 10px;
  background: rgba(0, 0, 0, 0.08);
}

.chat-message {
  padding: 8px 0;
  border-bottom: 1px solid rgba(255, 255, 255, 0.06);
}

.chat-message:last-child {
  border-bottom: 0;
}

.chat-meta {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  font-size: 0.82rem;
}

.chat-author {
  color: var(--accent);
  font-weight: bold;
}

#archive-assets {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.archive-asset {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  padding: 10px 12px;
  border: 1px solid var(--border-color);
  border-radius: 10px;
  color: inherit;
  text-decoration: none;
}

.archive-asset:hover {
  border-color: var(--accent);
  color: var(--accent);
}

.archive-asset-title {
  font-weight: bold;
}

.archive-asset--recording {
  cursor: pointer;
  align-items: center;
}

.archive-asset--recording .recording-info {
  flex: 1;
  min-width: 0;
}

.transcript-toggle {
  flex-shrink: 0;
  background: none;
  border: none;
  color: inherit;
  opacity: 0.5;
  cursor: pointer;
  padding: 4px;
  display: flex;
  align-items: center;
}

.transcript-toggle:hover {
  opacity: 1;
}

.transcript-toggle--open {
  opacity: 1;
  color: var(--accent);
}

.transcript-panel {
  padding: 8px 12px;
  font-size: 0.85rem;
  white-space: pre-wrap;
  color: var(--accent-alpha-70);
}

.archive-asset--active {
  border-color: var(--accent);
  background: rgba(255, 255, 255, 0.06);
}

.archive-session-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 12px;
  padding: 6px 0;
  margin-top: 40px;
}

.archive-session-header:first-child {
  margin-top: 0;
}

.archive-session-label {
  font-weight: bold;
  color: var(--accent);
}

.archive-session-time {
  font-size: 0.85rem;
  color: var(--accent-alpha-70);
}

.archive-session-empty {
  font-size: 0.85rem;
  color: var(--accent-alpha-70);
  padding: 4px 12px;
}

.archive-asset--download {
  background: rgba(255, 255, 255, 0.03);
  border-style: dashed;
  margin-top: 12px;
}

@media (max-width: 900px) {
  .meeting-layout {
    grid-template-columns: 1fr;
  }
}

/* Meeting listing */
.meeting-list { display: flex; flex-direction: column; gap: 12px; }

.meeting-list-item {
  display: block; text-decoration: none; color: inherit;
  border: 1px solid var(--border-color); border-radius: 14px;
  padding: 16px 18px; background: rgba(0, 0, 0, 0.08);
}
.meeting-list-item:hover { border-color: var(--accent); }

.meeting-list-header { display: flex; justify-content: space-between; align-items: center; gap: 12px; }
.meeting-list-title { font-weight: bold; font-size: 1.1rem; }
.meeting-list-meta { color: var(--accent-alpha-70); font-size: 0.85rem; margin-top: 6px; }

.meeting-badge { display: inline-block; padding: 2px 10px; border-radius: 8px; font-size: 0.8rem; border: 1px solid var(--border-color); }
.meeting-badge--live { background: var(--accent); color: var(--background); border-color: var(--accent); }
.meeting-badge--scheduled { border-color: var(--accent); color: var(--accent); }

.meeting-tags { display: flex; gap: 6px; flex-wrap: wrap; margin-top: 8px; }
.meeting-tag { border: 1px solid var(--border-color); padding: 2px 8px; border-radius: 6px; font-size: 0.78rem; }

.listing-search { width: 100%; border: 1px solid var(--border-color); border-radius: 10px; background: transparent; color: inherit; padding: 12px 14px; font: inherit; margin-bottom: 16px; box-sizing: border-box; }

.listing-hint { text-align: center; color: var(--accent-alpha-70); padding: 12px 0; font-size: 0.9rem; }
.listing-empty { text-align: center; padding: 40px 0; color: var(--accent-alpha-70); }
''';

  static const String _defaultSharedDirectoryHtml = r'''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
  <title>{{FOLDER_NAME}} - {{COLLECTION_NAME}}</title>
  <link rel="stylesheet" href="/styles.css">
  <link rel="stylesheet" href="{{HOME_URL}}shared/styles.css">
  {{NOSTR_STYLES}}
</head>
<body>
<div class="container">
  <header class="header">
    <div class="header__inner">
      <div class="header__logo">
        <a href="{{HOME_URL}}" style="text-decoration: none;">
          <div class="logo">{{COLLECTION_NAME}}</div>
        </a>
      </div>
      {{NOSTR_HEADER}}
    </div>
    <nav class="menu">
      <ul class="menu__inner">
        {{MENU_ITEMS}}
      </ul>
    </nav>
  </header>

  <div class="content">
    <div class="shared-directory">
      <div class="breadcrumb">
        {{BREADCRUMB}}
      </div>

      <div class="file-list-container">
        <div class="file-list">
          {{CONTENT}}
        </div>
      </div>
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

<script>
{{NOSTR_SCRIPTS}}
</script>
</body>
</html>
''';

  static const String _defaultSharedIndexHtml = r'''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
  <title>Shared Folders - {{COLLECTION_NAME}}</title>
  <link rel="stylesheet" href="/styles.css">
  <link rel="stylesheet" href="styles.css">
  {{NOSTR_STYLES}}
</head>
<body>
<div class="container">
  <header class="header">
    <div class="header__inner">
      <div class="header__logo">
        <a href="{{HOME_URL}}" style="text-decoration: none;">
          <div class="logo">{{COLLECTION_NAME}}</div>
        </a>
      </div>
      {{NOSTR_HEADER}}
    </div>
    <nav class="menu">
      <ul class="menu__inner">
        {{MENU_ITEMS}}
      </ul>
    </nav>
  </header>

  <div class="content">
    <div class="shared-index">
      <h2 class="shared-heading">Shared Folders</h2>
      <div class="shared-grid">
        {{CONTENT}}
      </div>
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

<script>
{{NOSTR_SCRIPTS}}
</script>
</body>
</html>
''';

  static const String _defaultSharedStylesCss = r'''
/* Shared Folders App - Theme Overrides */

/* Shared Index Page */
.shared-index {
  width: 100%;
}

.shared-heading {
  color: var(--accent);
  border-bottom: 2px dashed var(--accent);
  padding-bottom: 15px;
  margin-bottom: 20px;
  font-weight: normal;
}

/* Folder Cards Grid */
.shared-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
  gap: 16px;
}

@media (max-width: 683px) {
  .shared-grid {
    grid-template-columns: 1fr;
  }
}

.folder-card {
  display: block;
  padding: 20px;
  border: 1px solid var(--border-color);
  text-decoration: none;
  color: inherit;
  transition: background-color 0.2s ease, border-color 0.2s ease;
}

.folder-card:hover {
  background-color: var(--accent-alpha-20);
  border-color: var(--accent);
}

.folder-card-icon {
  font-size: 1.5rem;
  margin-bottom: 8px;
}

.folder-card-title {
  color: var(--accent);
  font-weight: bold;
  font-size: 1rem;
  margin-bottom: 4px;
}

.folder-card-desc {
  color: var(--accent-alpha-70);
  font-size: 0.85rem;
  line-height: 1.4;
}

.folder-card-badge {
  display: inline-block;
  font-size: 0.75rem;
  padding: 2px 8px;
  margin-top: 8px;
  color: var(--accent-alpha-70);
  border: 1px solid var(--border-color);
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.shared-empty {
  text-align: center;
  color: var(--accent-alpha-70);
  padding: 40px 0;
}

/* Directory Listing */
.shared-directory {
  width: 100%;
}

/* Breadcrumb */
.breadcrumb {
  display: flex;
  align-items: center;
  gap: 4px;
  margin-bottom: 20px;
  font-size: 0.95rem;
}

.breadcrumb-item {
  color: var(--accent-alpha-70);
  text-decoration: none;
}

.breadcrumb-item:hover {
  color: var(--accent);
}

.breadcrumb-item.active {
  color: var(--accent);
  font-weight: bold;
}

.breadcrumb-item:not(:last-child)::after {
  content: ' / ';
  color: var(--accent-alpha-70);
  margin-left: 4px;
}

/* File List Container */
.file-list-container {
  border: 1px solid var(--border-color);
  overflow: hidden;
}

.file-list {
  max-height: 70vh;
  overflow-y: auto;
}

/* File Item */
.file-item {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 12px 16px;
  border-bottom: 1px solid var(--border-color);
  transition: background-color 0.2s ease;
}

.file-item:last-child {
  border-bottom: none;
}

.file-item:hover {
  background-color: var(--accent-alpha-20);
}

.file-item a {
  color: inherit;
  text-decoration: none;
  display: flex;
  align-items: center;
  gap: 12px;
  flex: 1;
  min-width: 0;
}

.file-item a:hover {
  color: var(--accent);
}

/* File Icon */
.file-icon {
  font-size: 1.2rem;
  width: 28px;
  text-align: center;
  flex-shrink: 0;
}

/* File Name */
.file-name {
  flex: 1;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* File Size */
.file-size {
  font-size: 0.85rem;
  color: var(--accent-alpha-70);
  white-space: nowrap;
  min-width: 60px;
  text-align: right;
}

/* Scrollbar */
.file-list::-webkit-scrollbar {
  width: 6px;
}

.file-list::-webkit-scrollbar-track {
  background: transparent;
}

.file-list::-webkit-scrollbar-thumb {
  background: var(--accent-alpha-20);
  border-radius: 3px;
}

.file-list::-webkit-scrollbar-thumb:hover {
  background: var(--accent-alpha-70);
}
''';

  static const String _defaultStationIndexHtml = r'''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{{STATION_NAME}} - Geogram Station</title>
  <link rel="stylesheet" href="/styles.css">
  <link rel="stylesheet" href="styles.css">
</head>
<body>
  <div class="container">
    <header class="header">
      <div class="header-content">
        <div class="logo-section">
          <span class="logo">{{STATION_NAME}}</span>
        </div>
        <p class="subtitle">{{STATION_DESCRIPTION}}</p>
      </div>
    </header>

    <main class="main">
      <section class="station-info">
        <div class="info-grid">
          <div class="info-item">
            <span class="info-label">Version</span>
            <span class="info-value">{{VERSION}}</span>
          </div>
          <div class="info-item">
            <span class="info-label">Callsign</span>
            <span class="info-value">{{CALLSIGN}}</span>
          </div>
          <div class="info-item">
            <span class="info-label">Connected</span>
            <span class="info-value">{{CONNECTED_COUNT}} devices</span>
          </div>
          <div class="info-item">
            <span class="info-label">Status</span>
            <span class="info-value status-online">Running</span>
          </div>
        </div>
      </section>

      <section class="devices-section">
        <h2>Connected Devices</h2>
        <div class="devices-grid" id="devices-grid">
          {{DEVICES_LIST}}
        </div>
        <div class="no-devices" id="no-devices" style="display: none;">
          <p>No devices currently connected.</p>
          <p class="hint">Devices will appear here when they connect to this station.</p>
        </div>
      </section>

      <section class="api-section">
        <h2>API Endpoints</h2>
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
      <div class="footer-inner">
        <span>Powered by <a href="https://geogram.radio">Geogram</a></span>
      </div>
    </footer>
  </div>

  <script>
    document.addEventListener('DOMContentLoaded', function() {
      const devicesGrid = document.getElementById('devices-grid');
      const noDevices = document.getElementById('no-devices');

      if (!devicesGrid || devicesGrid.children.length === 0 || devicesGrid.innerHTML.trim() === '') {
        if (devicesGrid) devicesGrid.style.display = 'none';
        if (noDevices) noDevices.style.display = 'block';
      }
    });
  </script>
</body>
</html>
''';

  static const String _defaultStationStylesCss = r'''
/* Station styles - extends global */

.container {
  max-width: 900px;
  margin: 0 auto;
  padding: 0 20px;
}

.header {
  padding: 40px 0 30px;
  border-bottom: 1px solid var(--border-color);
  margin-bottom: 30px;
}

.header-content {
  text-align: center;
}

.logo-section {
  margin-bottom: 10px;
}

.logo {
  font-size: 1.8rem;
  font-weight: bold;
  color: var(--accent);
}

.subtitle {
  color: var(--accent-alpha-70);
  margin: 0;
  font-size: 1rem;
}

.main {
  padding: 20px 0;
}

/* Station Info Grid */
.station-info {
  margin-bottom: 40px;
}

.info-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
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
  font-size: 0.8rem;
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

.status-online {
  color: #4ade80;
}

/* Devices Section */
.devices-section {
  margin-bottom: 40px;
}

.devices-section h2 {
  margin-bottom: 20px;
  padding-bottom: 10px;
  border-bottom: 1px solid var(--border-color);
}

.devices-grid {
  display: grid;
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

.connection-badge.wifi {
  background: rgba(74, 222, 128, 0.2);
  color: #4ade80;
}

.connection-badge.internet {
  background: rgba(96, 165, 250, 0.2);
  color: #60a5fa;
}

.connection-badge.bluetooth {
  background: rgba(167, 139, 250, 0.2);
  color: #a78bfa;
}

.connection-badge.lora,
.connection-badge.radio {
  background: rgba(251, 191, 36, 0.2);
  color: #fbbf24;
}

.device-nickname {
  font-size: 1rem;
  margin-bottom: 8px;
  color: var(--color);
}

.device-meta {
  font-size: 0.85rem;
  color: var(--accent-alpha-70);
}

.no-devices {
  text-align: center;
  padding: 40px 20px;
  background: var(--accent-alpha-20);
  border-radius: 8px;
}

.no-devices p {
  margin: 0 0 10px 0;
}

.no-devices .hint {
  font-size: 0.9rem;
  color: var(--accent-alpha-70);
  margin: 0;
}

/* API Section */
.api-section {
  margin-bottom: 40px;
}

.api-section h2 {
  margin-bottom: 20px;
  padding-bottom: 10px;
  border-bottom: 1px solid var(--border-color);
}

.api-list {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

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

.api-link:hover {
  background: var(--accent-alpha-70);
}

.api-method {
  font-size: 0.75rem;
  font-weight: bold;
  padding: 2px 8px;
  background: var(--accent);
  color: var(--background);
  border-radius: 4px;
}

.api-path {
  font-family: monospace;
  font-weight: bold;
}

.api-desc {
  color: var(--accent-alpha-70);
  margin-left: auto;
  font-size: 0.9rem;
}

/* Footer */
.footer {
  padding: 30px 0;
  border-top: 1px solid var(--border-color);
  margin-top: 40px;
}

.footer-inner {
  text-align: center;
  color: var(--accent-alpha-70);
  font-size: 0.9rem;
}

.footer a {
  color: var(--accent);
  text-decoration: none;
}

.footer a:hover {
  text-decoration: underline;
}

/* Responsive */
@media (max-width: 600px) {
  .info-grid {
    grid-template-columns: repeat(2, 1fr);
  }

  .devices-grid {
    grid-template-columns: 1fr;
  }

  .api-link {
    flex-wrap: wrap;
  }

  .api-desc {
    width: 100%;
    margin-left: 0;
    margin-top: 5px;
  }
}
''';

  static const String _defaultStylesCss = r'''
/* Terminimal theme - Global styles */
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
  .logo { color: #fff; }
}

@media (prefers-color-scheme: dark) {
  .logo { color: #000; }
}

html { box-sizing: border-box; }
*, *:before, *:after { box-sizing: inherit; }

body {
  margin: 0;
  padding: 0;
  font-family: Hack, DejaVu Sans Mono, Monaco, Consolas, Ubuntu Mono, monospace;
  font-size: 1rem;
  line-height: 1.54;
  background-color: var(--background);
  color: var(--color);
  text-rendering: optimizeLegibility;
  -webkit-font-smoothing: antialiased;
  -webkit-text-size-adjust: 100%;
}

h1, h2, h3, h4, h5, h6 {
  display: flex;
  align-items: center;
  font-weight: bold;
  line-height: 1.3;
}

h1 { font-size: 1.4rem; }
h2 { font-size: 1.3rem; }
h3 { font-size: 1.2rem; }
h4, h5, h6 { font-size: 1.15rem; }

a { color: inherit; }

img {
  display: block;
  max-width: 100%;
}

p { margin-bottom: 20px; }

code {
  font-family: Hack, DejaVu Sans Mono, Monaco, Consolas, Ubuntu Mono, monospace;
  background: var(--accent-alpha-20);
  padding: 1px 6px;
  margin: 0 2px;
  font-size: .95rem;
}

pre {
  font-family: Hack, DejaVu Sans Mono, Monaco, Consolas, Ubuntu Mono, monospace;
  padding: 20px;
  font-size: .95rem;
  overflow: auto;
  border-top: 1px solid rgba(255,255,255,.1);
  border-bottom: 1px solid rgba(255,255,255,.1);
}

pre code {
  padding: 0;
  margin: 0;
  background: none;
}

blockquote {
  border-top: 1px solid var(--accent);
  border-bottom: 1px solid var(--accent);
  margin: 40px 0;
  padding: 25px;
}

blockquote p:first-of-type { margin-top: 0; }
blockquote p:last-of-type { margin-bottom: 0; }

ul, ol {
  margin-left: 30px;
  padding: 0;
}

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

/* Header */
.header {
  display: flex;
  flex-direction: column;
  position: relative;
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

.header__logo a {
  flex: 0 0 auto;
  max-width: 100%;
  text-decoration: none;
}

.logo {
  display: flex;
  align-items: center;
  text-decoration: none;
  background: var(--accent);
  color: #000;
  padding: 5px 10px;
}

/* Menu */
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

.menu__inner a:hover {
  color: var(--accent);
}

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

/* Content */
.content { display: flex; }

/* Posts */
.posts {
  width: 100%;
  margin: 0 auto;
}

.post {
  width: 100%;
  text-align: left;
  margin: 20px auto;
  padding: 20px 0;
}

.post:not(:last-of-type) {
  border-bottom: 1px solid var(--border-color);
}

.post-meta, .post-meta-inline {
  font-size: 1rem;
  margin-bottom: 10px;
  color: var(--accent-alpha-70);
}

.post-meta-inline { display: inline; }

.post-title {
  --border: 2px dashed var(--accent);
  position: relative;
  color: var(--accent);
  margin: 0 0 15px;
  padding-bottom: 15px;
  border-bottom: var(--border);
  font-weight: normal;
}

.post-title a {
  text-decoration: none;
  color: inherit;
}

.post-title a:hover {
  text-decoration: underline;
}

/* Add > prefix to post titles in list view */
.post.on-list .post-title::before {
  content: ">";
  color: var(--accent);
  margin-right: 10px;
}

/* Hover effect on entire post in list */
.post.on-list {
  transition: background-color 0.2s ease;
  padding-left: 10px;
  margin-left: -10px;
}

.post.on-list:hover {
  background-color: var(--accent-alpha-20);
}

.post-tags, .post-tags-inline {
  margin-bottom: 20px;
  font-size: 1rem;
  opacity: .5;
}

.post-tags { display: block; }
.post-tags-inline { display: inline; }

.post-tag {
  text-decoration: underline;
  color: inherit;
}

.post-content { margin-top: 30px; }

.post ul { list-style: none; }

.post ul li { position: relative; }

.post ul li:before {
  content: ">";
  position: absolute;
  left: -20px;
  color: var(--accent);
}

/* Post list */
.post-list .post-date {
  color: var(--accent-alpha-70);
  text-decoration: none;
}

.post-list a { text-decoration: none; }
.post-list .post-list-title { text-decoration: underline; }

/* Pagination */
.pagination { margin-top: 50px; }

.pagination__title {
  display: flex;
  text-align: center;
  position: relative;
  margin: 100px 0 20px;
}

.pagination__title-h {
  text-align: center;
  margin: 0 auto;
  padding: 5px 10px;
  background: var(--background);
  font-size: .8rem;
  text-transform: uppercase;
  letter-spacing: .1em;
  z-index: 1;
}

.pagination__title hr {
  position: absolute;
  left: 0;
  right: 0;
  width: 100%;
  margin-top: 15px;
  z-index: 0;
}

.pagination__buttons {
  display: flex;
  align-items: center;
  justify-content: center;
}

/* Buttons */
.button {
  position: relative;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-size: 1rem;
  border-radius: 8px;
  max-width: 40%;
  padding: 0;
  cursor: pointer;
  appearance: none;
  background: none;
  border: 1px solid var(--accent);
  color: var(--color);
}

.button + .button { margin-left: 10px; }

.button a {
  display: flex;
  padding: 8px 16px;
  text-decoration: none;
  color: inherit;
}

.button:hover {
  background: var(--accent-alpha-20);
}

/* Footer */
.footer {
  padding: 40px 0;
  flex-grow: 0;
  opacity: .5;
}

.footer__inner {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin: 0;
  max-width: 100%;
}

.footer a { color: inherit; }

.copyright {
  display: flex;
  flex-direction: row;
  align-items: center;
  font-size: 1rem;
}

@media (max-width: 683px) {
  .footer__inner { flex-direction: column; }
  .copyright { flex-direction: column; margin-top: 10px; }
}

/* Read more button */
a.read-more {
  display: inline-flex;
  background: none;
  padding: 0;
  margin: 20px 0;
  color: var(--accent);
  text-decoration: none;
}

a.read-more:hover {
  text-decoration: underline;
}

hr {
  width: 100%;
  border: none;
  background: var(--border-color);
  height: 1px;
}
''';

  static const String _defaultWwwIndexHtml = r'''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
  <title>{{TITLE}}</title>
  <link rel="stylesheet" href="/styles.css">
  <link rel="stylesheet" href="styles.css">
</head>
<body>
<div class="container">
  <header class="header">
    <div class="header__inner">
      <div class="header__logo">
        <a href="./" style="text-decoration: none;">
          <div class="logo">{{COLLECTION_NAME}}</div>
        </a>
      </div>
    </div>
    <nav class="menu">
      <ul class="menu__inner">
        {{MENU_ITEMS}}
      </ul>
    </nav>
  </header>

  <div class="content">
    {{CONTENT}}
  </div>

  <footer class="footer">
    <div class="footer__inner">
      <div class="copyright">
        <span>published via geogram</span>
      </div>
    </div>
  </footer>
</div>
</body>
</html>
''';

  static const String _defaultWwwStylesCss = r'''
/* Homepage styles - extends global */
''';

}
