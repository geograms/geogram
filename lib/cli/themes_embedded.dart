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
    'default/events/index.html': _defaultEventsIndexHtml,
    'default/events/styles.css': _defaultEventsStylesCss,
    'default/files/index.html': _defaultFilesIndexHtml,
    'default/files/styles.css': _defaultFilesStylesCss,
    'default/forum/index.html': _defaultForumIndexHtml,
    'default/forum/styles.css': _defaultForumStylesCss,
    'default/home/index.html': _defaultHomeIndexHtml,
    'default/home/styles.css': _defaultHomeStylesCss,
    'default/meet/index.html': _defaultMeetIndexHtml,
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
      <h1 class="post-title"><a href="#">{{POST_TITLE}}</a></h1>
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

/* Feedback section */
.feedback-section {
  margin-top: 30px;
  padding: 20px 0;
  border-top: 1px solid var(--border-color);
  display: flex;
  align-items: center;
  gap: 30px;
}

.like-button {
  position: relative;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  padding: 8px 16px;
  background: none;
  border: 1px solid var(--accent);
  color: var(--color);
  font-family: inherit;
  font-size: 1rem;
  cursor: pointer;
  border-radius: 8px;
  transition: background-color 0.2s ease;
}

.like-button:hover {
  background: var(--accent-alpha-20);
}

.like-button.liked {
  background: var(--accent);
  color: #000;
}

.like-button:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.like-count {
  color: var(--accent-alpha-70);
  font-size: 0.95rem;
}

.nostr-notice {
  font-size: 0.85rem;
  color: var(--accent-alpha-70);
}

.nostr-notice a {
  color: var(--accent);
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

  static const String _defaultEventsIndexHtml = r'''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{{TITLE}} - Events</title>
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
          <span class="badge">Events</span>
        </nav>
      </div>
    </div>
  </header>

  <main class="main">
    <div class="container">
      <div class="events-header">
        <div class="search-container">
          <input type="text" class="input search-input" placeholder="Search events..." id="search">
        </div>
        <div class="view-toggle">
          <button class="btn btn-secondary active" data-view="list">List</button>
          <button class="btn btn-secondary" data-view="calendar">Calendar</button>
        </div>
      </div>

      <div class="events-list" id="events">
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
      const events = document.querySelectorAll('.event-item');
      events.forEach(event => {
        const text = event.textContent.toLowerCase();
        event.style.display = text.includes(query) ? '' : 'none';
      });
    });

    // View toggle
    document.querySelectorAll('.view-toggle .btn').forEach(btn => {
      btn.addEventListener('click', function() {
        document.querySelectorAll('.view-toggle .btn').forEach(b => b.classList.remove('active'));
        this.classList.add('active');
        // View switching logic would go here
      });
    });
  </script>
</body>
</html>
''';

  static const String _defaultEventsStylesCss = r'''
/* Events App - Theme Overrides */

/* Events Header */
.events-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: var(--spacing-lg);
  gap: var(--spacing-md);
}

@media (max-width: 640px) {
  .events-header {
    flex-direction: column;
    align-items: stretch;
  }
}

.view-toggle {
  display: flex;
  gap: var(--spacing-xs);
}

.view-toggle .btn.active {
  background-color: var(--color-accent);
  color: white;
}

/* Events List */
.events-list {
  display: flex;
  flex-direction: column;
  gap: var(--spacing-md);
}

/* Event Item */
.event-item {
  display: flex;
  gap: var(--spacing-lg);
  background-color: var(--color-bg);
  border: 1px solid var(--color-border-light);
  border-radius: var(--border-radius);
  padding: var(--spacing-lg);
  transition: box-shadow var(--transition-fast);
}

.event-item:hover {
  box-shadow: var(--shadow-md);
}

@media (max-width: 640px) {
  .event-item {
    flex-direction: column;
  }
}

/* Event Date Block */
.event-date-block {
  flex-shrink: 0;
  width: 80px;
  text-align: center;
  padding: var(--spacing-md);
  background-color: var(--color-bg-secondary);
  border-radius: var(--border-radius);
}

.event-month {
  font-size: var(--font-size-sm);
  font-weight: 600;
  text-transform: uppercase;
  color: var(--color-accent);
  margin-bottom: var(--spacing-xs);
}

.event-day {
  font-size: var(--font-size-3xl);
  font-weight: 700;
  line-height: 1;
  color: var(--color-text);
}

.event-weekday {
  font-size: var(--font-size-xs);
  color: var(--color-text-muted);
  margin-top: var(--spacing-xs);
}

/* Event Content */
.event-content {
  flex: 1;
  min-width: 0;
}

.event-title {
  font-size: var(--font-size-xl);
  font-weight: 600;
  margin-bottom: var(--spacing-sm);
  color: var(--color-text);
}

.event-title a {
  color: inherit;
}

.event-title a:hover {
  color: var(--color-accent);
}

.event-meta {
  display: flex;
  flex-wrap: wrap;
  gap: var(--spacing-md);
  margin-bottom: var(--spacing-md);
  font-size: var(--font-size-sm);
  color: var(--color-text-muted);
}

.event-meta-item {
  display: flex;
  align-items: center;
  gap: var(--spacing-xs);
}

.event-description {
  color: var(--color-text-secondary);
  margin-bottom: var(--spacing-md);
}

.event-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--spacing-md);
}

.event-tags {
  display: flex;
  flex-wrap: wrap;
  gap: var(--spacing-xs);
}

.event-tag {
  font-size: var(--font-size-xs);
  padding: var(--spacing-xs) var(--spacing-sm);
  background-color: var(--color-bg-secondary);
  border-radius: var(--border-radius-sm);
  color: var(--color-text-secondary);
}

/* Event Status */
.event-status {
  font-size: var(--font-size-xs);
  font-weight: 500;
  padding: var(--spacing-xs) var(--spacing-sm);
  border-radius: var(--border-radius-sm);
}

.event-status.upcoming {
  background-color: var(--color-success);
  color: white;
}

.event-status.ongoing {
  background-color: var(--color-warning);
  color: white;
}

.event-status.past {
  background-color: var(--color-bg-tertiary);
  color: var(--color-text-muted);
}

/* Attendance */
.event-attendance {
  display: flex;
  align-items: center;
  gap: var(--spacing-sm);
  font-size: var(--font-size-sm);
  color: var(--color-text-muted);
}

.attendance-avatars {
  display: flex;
}

.attendance-avatars .avatar {
  width: 24px;
  height: 24px;
  font-size: var(--font-size-xs);
  margin-left: -8px;
  border: 2px solid var(--color-bg);
}

.attendance-avatars .avatar:first-child {
  margin-left: 0;
}

/* Featured Event */
.event-item.featured {
  border-left: 4px solid var(--color-accent);
}

/* Cancelled Event */
.event-item.cancelled {
  opacity: 0.6;
}

.event-item.cancelled .event-title {
  text-decoration: line-through;
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
  <link rel="stylesheet" href="/styles.css">
  <link rel="stylesheet" href="styles.css?v=1">
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
        <h1 class="meeting-title">{{ROOM_TITLE}}</h1>
        <div class="meeting-subtitle">{{ROOM_SUBTITLE}}</div>
        <div id="status">{{STATUS_TEXT}}</div>
        <div id="nostr-gate-msg">Use the identity button above to authenticate before joining the meeting.</div>
        <div id="join-form">
          <input id="nickname" type="text" placeholder="Nickname (optional)" maxlength="20" autofocus>
          <div class="button-row">
            <button id="btn-join-listener" type="button">Join as Listener</button>
            <button id="btn-join-speaker" type="button">Join as Speaker</button>
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

.meeting-title {
  margin: 0 0 6px 0;
  font-size: 1.4rem;
}

.meeting-subtitle,
#status,
#nostr-gate-msg,
.participant-role,
.chat-meta {
  color: var(--accent-alpha-70);
}

#status {
  font-size: 0.95rem;
  margin-bottom: 14px;
}

#nostr-gate-msg {
  margin-bottom: 16px;
}

#join-form {
  display: none;
  gap: 12px;
  flex-wrap: wrap;
  align-items: center;
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

#btn-join-speaker,
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

@media (max-width: 900px) {
  .meeting-layout {
    grid-template-columns: 1fr;
  }
}
''';

  static const String _defaultSharedDirectoryHtml = r'''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
  <title>{{FOLDER_NAME}} - {{COLLECTION_NAME}}</title>
  <link rel="stylesheet" href="/styles.css">
  <link rel="stylesheet" href="../styles.css">
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
        <a class="breadcrumb-item" href="../">Shared</a>
        <span class="breadcrumb-item active">{{FOLDER_NAME}}</span>
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
