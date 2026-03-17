/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';

import '../util/nostr_login_scripts.dart';
import 'web_theme_service.dart';

class EventWebPageAssets {
  final String html;
  final String globalStyles;
  final String appStyles;

  const EventWebPageAssets({
    required this.html,
    required this.globalStyles,
    required this.appStyles,
  });
}

class EventWebPageService {
  static final EventWebPageService _instance =
      EventWebPageService._internal();

  factory EventWebPageService() => _instance;

  EventWebPageService._internal();

  Future<EventWebPageAssets> buildListingPage({
    required Map<String, dynamic> data,
    required String logoText,
    String menuItems = '',
  }) async {
    final themeService = WebThemeService();
    await themeService.init();

    final template =
        await themeService.getNamedTemplate('events', 'index.html') ??
            await themeService.getTemplate('events') ??
            _fallbackListingTemplate;
    final globalStyles = await themeService.getGlobalStyles() ?? '';
    final appStyles = await themeService.getAppStyles('events') ?? '';
    final dataJson = _jsonForScript(data);

    final html = themeService.processTemplate(template, {
      'TITLE': 'Events',
      'LOGO_TEXT': _escape(logoText),
      'DATA_JSON': dataJson,
      'MENU_ITEMS': menuItems,
      'NOSTR_STYLES': getNostrLoginStyles(),
      'NOSTR_HEADER': getNostrLoginHeaderHtml(),
      'GLOBAL_STYLES': globalStyles,
      'APP_STYLES': appStyles,
      'SCRIPTS': getNostrLoginScripts(),
    });

    return EventWebPageAssets(
      html: html,
      globalStyles: globalStyles,
      appStyles: appStyles,
    );
  }

  Future<EventWebPageAssets> buildEventPage({
    required Map<String, dynamic> data,
    required String logoText,
    String menuItems = '',
  }) async {
    final themeService = WebThemeService();
    await themeService.init();

    final template =
        await themeService.getNamedTemplate('events', 'event.html') ??
            _fallbackEventTemplate;
    final globalStyles = await themeService.getGlobalStyles() ?? '';
    final appStyles = await themeService.getAppStyles('events') ?? '';
    final dataJson = _jsonForScript(data);

    final title = data['title'] as String? ?? 'Event';

    final html = themeService.processTemplate(template, {
      'TITLE': _escape(title),
      'LOGO_TEXT': _escape(logoText),
      'DATA_JSON': dataJson,
      'MENU_ITEMS': menuItems,
      'NOSTR_STYLES': getNostrLoginStyles(),
      'NOSTR_HEADER': getNostrLoginHeaderHtml(),
      'GLOBAL_STYLES': globalStyles,
      'APP_STYLES': appStyles,
      'SCRIPTS': getNostrLoginScripts(),
    });

    return EventWebPageAssets(
      html: html,
      globalStyles: globalStyles,
      appStyles: appStyles,
    );
  }

  String _escape(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  String _jsonForScript(Map<String, dynamic> data) {
    return jsonEncode(data).replaceAll('</', '<\\/');
  }

  static const String _fallbackListingTemplate = '''
<!DOCTYPE html>
<html lang="en">
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
    <div class="events-shell">
      <input id="events-search" class="listing-search" type="text" placeholder="Search events..." autofocus>
      <div id="year-tabs" class="year-tabs"></div>
      <div id="events-list" class="events-list"></div>
      <div id="events-hint" class="listing-hint" style="display:none"></div>
    </div>
  </main>
  <footer class="footer">
    <div class="footer__inner">
      <div class="copyright"><span>powered by geogram</span></div>
    </div>
  </footer>
</div>
<script>
  window.GEOGRAM_EVENTS = {{DATA_JSON}};
  {{SCRIPTS}}
</script>
</body>
</html>
''';

  static const String _fallbackEventTemplate = '''
<!DOCTYPE html>
<html lang="en">
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
    <div id="event-detail" class="event-detail"></div>
  </main>
  <footer class="footer">
    <div class="footer__inner">
      <div class="copyright"><span>powered by geogram</span></div>
    </div>
  </footer>
</div>
<script>
  window.GEOGRAM_EVENT = {{DATA_JSON}};
  {{SCRIPTS}}
</script>
</body>
</html>
''';
}
