/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

// Web viewer service for NDF documents — generates read-only HTML pages.
// Pure Dart, no Flutter dependencies.

import 'dart:convert' show base64Encode;
import 'dart:typed_data';

import '../../util/feedback_comment_utils.dart';
import '../../util/html_utils.dart';
import '../../util/nostr_login_scripts.dart';
import '../../util/station_html_templates.dart';
import '../models/document_content.dart';
import '../models/ndf_document.dart';
import '../models/ndf_interaction_settings.dart';
import '../models/presentation_content.dart';
import '../models/spreadsheet_content.dart';
import '../models/todo_content.dart';
import '../models/voicememo_content.dart';
import 'ndf_service.dart';

/// Singleton service for rendering NDF documents as HTML pages.
class NdfWebViewerService {
  static final NdfWebViewerService _instance =
      NdfWebViewerService._internal();

  factory NdfWebViewerService() => _instance;

  NdfWebViewerService._internal();

  final NdfService _ndfService = NdfService();

  static const _defaultColWidth = 100.0;
  static const _rowHeaderWidth = 40;

  /// Build an HTML page for an NDF document.
  /// Dispatches by document type.
  String? buildPage(
    Uint8List ndfBytes, {
    String ownerIdentifier = '',
    String workspaceName = '',
    String menuItems = '',
    String logoText = '',
    String logoHref = '../../',
    NdfInteractionSettings interaction = const NdfInteractionSettings(),
    int likesCount = 0,
    List<String> likedHexPubkeys = const [],
    List<FeedbackComment> comments = const [],
    String ownerNpub = '',
    String documentFilename = '',
  }) {
    final metadata = _ndfService.readMetadataFromBytes(ndfBytes);
    if (metadata == null) return null;

    switch (metadata.type) {
      case NdfDocumentType.spreadsheet:
        return buildSpreadsheetPage(
          ndfBytes,
          metadata: metadata,
          ownerIdentifier: ownerIdentifier,
          workspaceName: workspaceName,
          menuItems: menuItems,
          logoText: logoText,
          logoHref: logoHref,
          interaction: interaction,
          likesCount: likesCount,
          likedHexPubkeys: likedHexPubkeys,
          comments: comments,
          ownerNpub: ownerNpub,
          documentFilename: documentFilename,
        );
      case NdfDocumentType.document:
        return buildDocumentPage(
          ndfBytes,
          metadata: metadata,
          ownerIdentifier: ownerIdentifier,
          workspaceName: workspaceName,
          menuItems: menuItems,
          logoText: logoText,
          logoHref: logoHref,
          interaction: interaction,
          likesCount: likesCount,
          likedHexPubkeys: likedHexPubkeys,
          comments: comments,
          ownerNpub: ownerNpub,
          documentFilename: documentFilename,
        );
      case NdfDocumentType.presentation:
        return _buildPresentationPage(ndfBytes, metadata: metadata,
          ownerIdentifier: ownerIdentifier, workspaceName: workspaceName,
          menuItems: menuItems, logoText: logoText, logoHref: logoHref,
          interaction: interaction, likesCount: likesCount,
          likedHexPubkeys: likedHexPubkeys, comments: comments,
          ownerNpub: ownerNpub, documentFilename: documentFilename);
      case NdfDocumentType.voicememo:
        return _buildVoiceMemoPage(ndfBytes, metadata: metadata,
          ownerIdentifier: ownerIdentifier, workspaceName: workspaceName,
          menuItems: menuItems, logoText: logoText, logoHref: logoHref,
          interaction: interaction, likesCount: likesCount,
          likedHexPubkeys: likedHexPubkeys, comments: comments,
          ownerNpub: ownerNpub, documentFilename: documentFilename);
      case NdfDocumentType.todo:
        return _buildTodoPage(ndfBytes, metadata: metadata,
          ownerIdentifier: ownerIdentifier, workspaceName: workspaceName,
          menuItems: menuItems, logoText: logoText, logoHref: logoHref,
          interaction: interaction, likesCount: likesCount,
          likedHexPubkeys: likedHexPubkeys, comments: comments,
          ownerNpub: ownerNpub, documentFilename: documentFilename);
      default:
        return null; // Other types not yet supported
    }
  }

  /// Build a read-only HTML page for a spreadsheet NDF document.
  String? buildSpreadsheetPage(
    Uint8List ndfBytes, {
    required NdfDocument metadata,
    String ownerIdentifier = '',
    String workspaceName = '',
    String menuItems = '',
    String logoText = '',
    String logoHref = '../../',
    NdfInteractionSettings interaction = const NdfInteractionSettings(),
    int likesCount = 0,
    List<String> likedHexPubkeys = const [],
    List<FeedbackComment> comments = const [],
    String ownerNpub = '',
    String documentFilename = '',
  }) {
    // Read main content
    final mainJson =
        _ndfService.readArchiveJsonFromBytes(ndfBytes, 'content/main.json');
    if (mainJson == null) return null;

    final content = SpreadsheetContent.fromJson(mainJson);

    // Read all sheets
    final sheets = <SpreadsheetSheet>[];
    for (final sheetId in content.sheets) {
      final sheetJson = _ndfService.readArchiveJsonFromBytes(
          ndfBytes, 'content/$sheetId.json');
      if (sheetJson != null) {
        sheets.add(SpreadsheetSheet.fromJson(sheetJson));
      }
    }

    if (sheets.isEmpty) return null;

    final title = metadata.title.isNotEmpty ? metadata.title : 'Spreadsheet';
    final logo = logoText.isNotEmpty ? logoText : ownerIdentifier;

    // Build sheet content HTML
    final sheetsHtml = StringBuffer();
    final tabsHtml = StringBuffer();

    for (var i = 0; i < sheets.length; i++) {
      final sheet = sheets[i];
      final isActive = i == 0;
      final safeId = 'sheet-${sheet.id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '')}';

      // Tab button
      tabsHtml.write(
        '<button class="sheet-tab${isActive ? ' active' : ''}" '
        'onclick="switchSheet(\'$safeId\')">'
        '${escapeHtml(sheet.name)}</button>',
      );

      // Sheet table
      sheetsHtml.write(
        '<div class="sheet-panel${isActive ? ' active' : ''}" id="$safeId">',
      );
      sheetsHtml.write(_buildSheetTable(sheet));
      sheetsHtml.write('</div>');
    }

    // Build the spreadsheet-specific content
    final contentHtml = StringBuffer();
    if (sheets.length > 1) {
      contentHtml.write('<div class="sheet-tabs">$tabsHtml</div>');
    }
    contentHtml.write('<div class="sheets-container">$sheetsHtml</div>');

    final extraScripts = sheets.length > 1 ? '<script>${_getTabScript()}</script>' : '';

    return _buildPageShell(
      title: title,
      ownerIdentifier: ownerIdentifier,
      workspaceName: workspaceName,
      menuItems: menuItems,
      logo: logo,
      logoHref: logoHref,
      appStyles: _getSpreadsheetStyles(),
      contentHtml: contentHtml.toString(),
      interaction: interaction,
      likesCount: likesCount,
      likedHexPubkeys: likedHexPubkeys,
      comments: comments,
      ownerNpub: ownerNpub,
      documentFilename: documentFilename,
      extraScripts: extraScripts,
      containerClass: 'container',
    );
  }

  /// Build a read-only HTML page for a rich text NDF document.
  String? buildDocumentPage(
    Uint8List ndfBytes, {
    required NdfDocument metadata,
    String ownerIdentifier = '',
    String workspaceName = '',
    String menuItems = '',
    String logoText = '',
    String logoHref = '../../',
    NdfInteractionSettings interaction = const NdfInteractionSettings(),
    int likesCount = 0,
    List<String> likedHexPubkeys = const [],
    List<FeedbackComment> comments = const [],
    String ownerNpub = '',
    String documentFilename = '',
  }) {
    final mainJson =
        _ndfService.readArchiveJsonFromBytes(ndfBytes, 'content/main.json');
    if (mainJson == null) return null;

    final content = DocumentContent.fromJson(mainJson);
    final title = metadata.title.isNotEmpty ? metadata.title : 'Document';
    final logo = logoText.isNotEmpty ? logoText : ownerIdentifier;

    // Render document elements to HTML
    final contentHtml = StringBuffer();
    contentHtml.write('<div class="doc-content">');
    for (final element in content.content) {
      contentHtml.write(_renderDocElement(element, ndfBytes));
    }
    contentHtml.write('</div>');

    return _buildPageShell(
      title: title,
      ownerIdentifier: ownerIdentifier,
      workspaceName: workspaceName,
      menuItems: menuItems,
      logo: logo,
      logoHref: logoHref,
      appStyles: _getDocumentStyles(),
      contentHtml: contentHtml.toString(),
      interaction: interaction,
      likesCount: likesCount,
      likedHexPubkeys: likedHexPubkeys,
      comments: comments,
      ownerNpub: ownerNpub,
      documentFilename: documentFilename,
    );
  }

  /// Shared page shell used by all NDF document type renderers.
  String _buildPageShell({
    required String title,
    required String ownerIdentifier,
    required String workspaceName,
    required String menuItems,
    required String logo,
    required String logoHref,
    required String appStyles,
    required String contentHtml,
    required NdfInteractionSettings interaction,
    required int likesCount,
    required List<String> likedHexPubkeys,
    required List<FeedbackComment> comments,
    required String ownerNpub,
    required String documentFilename,
    String extraScripts = '',
    String containerClass = 'container',
    bool showWorkspaceName = true,
  }) {
    final nostrHeaderHtml = getNostrLoginHeaderHtml();
    final nostrStyles = getNostrLoginStyles();
    final nostrScripts = getNostrLoginScripts();
    final globalStyles = StationHtmlTemplates.getBaseStyles();

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

    return '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
  <title>${escapeHtml(title)}${ownerIdentifier.isNotEmpty ? ' - ${escapeHtml(ownerIdentifier)}' : ''}</title>
  $nostrStyles
  <style>$globalStyles</style>
  <style>$appStyles</style>
</head>
<body>
<div class="$containerClass">
$headerHtml
  <div class="content">
    <div class="post">
      <h1 class="post-title">${escapeHtml(title)}</h1>
      ${showWorkspaceName && workspaceName.isNotEmpty ? '<div class="post-meta-inline"><span class="post-date">${escapeHtml(workspaceName)}</span></div>' : ''}
      $contentHtml
      ${_buildFeedbackHtml(interaction, likesCount, comments)}
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
${interaction.permitLikes ? _getLikesScript(ownerNpub, likesCount, likedHexPubkeys, documentFilename) : ''}
${interaction.permitComments ? _getCommentsScript(ownerNpub, documentFilename) : ''}
$extraScripts
<script>$nostrScripts</script>
</body>
</html>''';
  }

  // ============================================================
  // Document element renderers
  // ============================================================

  String _renderDocElement(DocumentElement element, Uint8List ndfBytes) {
    switch (element.type) {
      case DocumentElementType.heading:
        final h = element as HeadingElement;
        final level = h.level.clamp(1, 6);
        return '<h$level>${_renderSpans(h.content)}</h$level>';

      case DocumentElementType.paragraph:
        final p = element as ParagraphElement;
        if (p.content.isEmpty || (p.content.length == 1 && p.content.first.value.isEmpty)) {
          return '<p><br></p>';
        }
        return '<p>${_renderSpans(p.content)}</p>';

      case DocumentElementType.list:
        final l = element as ListElement;
        return _renderList(l.ordered, l.items);

      case DocumentElementType.image:
        final img = element as ImageElement;
        return _renderImage(img, ndfBytes);

      case DocumentElementType.table:
        final t = element as TableElement;
        return _renderTable(t);

      case DocumentElementType.code:
        final c = element as CodeElement;
        final langAttr = c.language != null && c.language!.isNotEmpty
            ? ' class="language-${escapeHtml(c.language!)}"'
            : '';
        return '<pre><code$langAttr>${escapeHtml(c.content)}</code></pre>';

      case DocumentElementType.blockquote:
        final bq = element as BlockquoteElement;
        return '<blockquote><p>${_renderSpans(bq.content)}</p></blockquote>';

      case DocumentElementType.horizontalRule:
        return '<hr>';

      case DocumentElementType.formEmbed:
        return ''; // Forms not rendered in read-only view
    }
  }

  String _renderSpans(List<RichTextSpan> spans) {
    final buf = StringBuffer();
    for (final span in spans) {
      var text = escapeHtml(span.value);
      if (text.isEmpty) continue;

      // Apply inline styles
      final styles = <String>[];
      if (span.color != null) styles.add('color:${span.color}');
      if (span.background != null) styles.add('background-color:${span.background}');
      if (span.fontSize != null) styles.add('font-size:${span.fontSize}px');

      if (styles.isNotEmpty) {
        text = '<span style="${styles.join(';')}">$text</span>';
      }

      // Apply marks (innermost first)
      if (span.isCode) text = '<code>$text</code>';
      if (span.marks.contains(TextMark.subscript)) text = '<sub>$text</sub>';
      if (span.marks.contains(TextMark.superscript)) text = '<sup>$text</sup>';
      if (span.isStrikethrough) text = '<del>$text</del>';
      if (span.isUnderline) text = '<u>$text</u>';
      if (span.isItalic) text = '<em>$text</em>';
      if (span.isBold) text = '<strong>$text</strong>';

      // Wrap in link if present
      if (span.link != null && span.link!.isNotEmpty) {
        text = '<a href="${escapeHtml(span.link!)}" target="_blank" rel="noopener">$text</a>';
      }

      buf.write(text);
    }
    return buf.toString();
  }

  String _renderList(bool ordered, List<ListItem> items) {
    final tag = ordered ? 'ol' : 'ul';
    final buf = StringBuffer('<$tag>');
    for (final item in items) {
      buf.write('<li>${_renderSpans(item.content)}');
      if (item.children != null) {
        buf.write(_renderList(item.children!.ordered, item.children!.items));
      }
      buf.write('</li>');
    }
    buf.write('</$tag>');
    return buf.toString();
  }

  String _renderImage(ImageElement img, Uint8List ndfBytes) {
    // For asset:// references, we can't serve them inline — show alt text or placeholder
    if (img.isAsset) {
      // Try to read image from NDF archive and embed as data URI
      final assetPath = 'assets/${img.assetPath}';
      final imageBytes = _ndfService.readArchiveFileFromBytes(ndfBytes, assetPath);
      if (imageBytes != null) {
        final ext = img.assetPath?.split('.').last.toLowerCase() ?? 'png';
        final mime = ext == 'jpg' || ext == 'jpeg' ? 'image/jpeg'
            : ext == 'png' ? 'image/png'
            : ext == 'gif' ? 'image/gif'
            : ext == 'svg' ? 'image/svg+xml'
            : ext == 'webp' ? 'image/webp'
            : 'image/png';
        final b64 = base64Encode(imageBytes);
        final alt = img.alt != null ? ' alt="${escapeHtml(img.alt!)}"' : '';
        final caption = img.caption != null
            ? '<figcaption>${escapeHtml(img.caption!)}</figcaption>'
            : '';
        return '<figure><img src="data:$mime;base64,$b64"$alt style="max-width:100%">$caption</figure>';
      }
    }
    // External URL or failed asset
    final alt = img.alt ?? img.caption ?? '';
    if (img.src.startsWith('http')) {
      return '<figure><img src="${escapeHtml(img.src)}" alt="${escapeHtml(alt)}" style="max-width:100%">'
          '${img.caption != null ? '<figcaption>${escapeHtml(img.caption!)}</figcaption>' : ''}'
          '</figure>';
    }
    return img.caption != null ? '<p><em>${escapeHtml(img.caption!)}</em></p>' : '';
  }

  String _renderTable(TableElement table) {
    final buf = StringBuffer('<table class="doc-table">');
    for (final row in table.rows) {
      buf.write('<tr>');
      final cellTag = row.header ? 'th' : 'td';
      for (final cell in row.cells) {
        final attrs = StringBuffer();
        if (cell.colspan != null && cell.colspan! > 1) {
          attrs.write(' colspan="${cell.colspan}"');
        }
        if (cell.rowspan != null && cell.rowspan! > 1) {
          attrs.write(' rowspan="${cell.rowspan}"');
        }
        buf.write('<$cellTag$attrs>${_renderSpans(cell.content)}</$cellTag>');
      }
      buf.write('</tr>');
    }
    buf.write('</table>');
    return buf.toString();
  }

  // ============================================================
  // Document-specific styles
  // ============================================================

  String _getDocumentStyles() {
    return '''
.doc-content {
  line-height: 1.7;
  font-size: 1rem;
}
.doc-content h1 { font-size: 1.6rem; margin: 1.5em 0 0.5em; }
.doc-content h2 { font-size: 1.3rem; margin: 1.3em 0 0.4em; }
.doc-content h3 { font-size: 1.1rem; margin: 1.2em 0 0.3em; }
.doc-content h4, .doc-content h5, .doc-content h6 { font-size: 1rem; margin: 1em 0 0.3em; }
.doc-content p { margin: 0 0 0.8em; }
.doc-content a { color: var(--accent); }
.doc-content a:hover { text-decoration: underline; }
.doc-content ul, .doc-content ol { margin: 0 0 0.8em; padding-left: 1.5em; }
.doc-content li { margin-bottom: 0.3em; }
.doc-content blockquote {
  border-left: 3px solid var(--accent-alpha-70);
  margin: 0 0 0.8em;
  padding: 0.5em 1em;
  opacity: 0.85;
}
.doc-content pre {
  background: var(--accent-alpha-20);
  border: 1px solid var(--border-color);
  border-radius: 4px;
  padding: 12px 16px;
  overflow-x: auto;
  margin: 0 0 0.8em;
  font-size: 0.85rem;
}
.doc-content code {
  background: var(--accent-alpha-20);
  padding: 1px 4px;
  border-radius: 3px;
  font-size: 0.9em;
}
.doc-content pre code {
  background: none;
  padding: 0;
  border-radius: 0;
}
.doc-content hr {
  border: none;
  border-top: 1px solid var(--border-color);
  margin: 1.5em 0;
}
.doc-content figure {
  margin: 1em 0;
  text-align: center;
}
.doc-content figcaption {
  font-size: 0.85rem;
  opacity: 0.7;
  margin-top: 0.5em;
}
.doc-content img {
  border-radius: 4px;
}
.doc-table {
  border-collapse: collapse;
  margin: 0 0 0.8em;
  width: 100%;
  font-size: 0.9rem;
}
.doc-table th, .doc-table td {
  border: 1px solid var(--border-color);
  padding: 6px 10px;
  text-align: left;
}
.doc-table th {
  font-weight: bold;
  background: var(--accent-alpha-20);
}

/* Feedback (shared with spreadsheet) */
''' + _getFeedbackStyles() + '''
''';
  }

  // ============================================================
  // Presentation viewer (with template decorations)
  // ============================================================

  String? _buildPresentationPage(Uint8List ndfBytes, {
    required NdfDocument metadata,
    String ownerIdentifier = '', String workspaceName = '',
    String menuItems = '', String logoText = '', String logoHref = '../../',
    NdfInteractionSettings interaction = const NdfInteractionSettings(),
    int likesCount = 0, List<String> likedHexPubkeys = const [],
    List<FeedbackComment> comments = const [], String ownerNpub = '',
    String documentFilename = '',
  }) {
    final mainJson = _ndfService.readArchiveJsonFromBytes(ndfBytes, 'content/main.json');
    if (mainJson == null) return null;

    final content = PresentationContent.fromJson(mainJson);
    final title = metadata.title.isNotEmpty ? metadata.title : 'Presentation';
    final logo = logoText.isNotEmpty ? logoText : ownerIdentifier;
    final theme = content.theme;

    // Match theme to a template for decorations
    final template = _matchTemplate(theme.colors);

    // Read all slides
    final slides = <PresentationSlide>[];
    for (final slideId in content.slides) {
      var slideJson = _ndfService.readArchiveJsonFromBytes(ndfBytes, 'content/$slideId.json');
      slideJson ??= _ndfService.readArchiveJsonFromBytes(ndfBytes, 'content/slides/$slideId.json');
      if (slideJson != null) {
        slides.add(PresentationSlide.fromJson(slideJson));
      }
    }
    if (slides.isEmpty) return null;

    // Build slides HTML with template decorations
    final slidesHtml = StringBuffer();
    for (var i = 0; i < slides.length; i++) {
      final slide = slides[i];
      final isActive = i == 0;
      final bg = slide.background;

      // Background: gradient or solid
      final bgStyles = <String>[];
      if (template != null && template.hasGradientBackground) {
        bgStyles.add('background:linear-gradient(135deg,${template.gradientStart ?? theme.colors.background},${template.gradientEnd ?? theme.colors.background})');
      } else {
        bgStyles.add('background-color:${bg.color ?? theme.colors.background}');
      }
      bgStyles.add('color:${theme.colors.text}');

      slidesHtml.write('<div class="slide${isActive ? ' active' : ''}" data-index="$i" style="${bgStyles.join(';')};">');

      // Template decorations (rendered behind content)
      if (template != null) {
        if (template.titleBarColor != null) {
          final y = template.titleBarY ?? '0%';
          final h = template.titleBarH ?? '15%';
          slidesHtml.write('<div class="slide-decor" style="left:0;top:$y;width:100%;height:$h;background:${template.titleBarColor};"></div>');
        }
        for (final d in template.decorations) {
          slidesHtml.write(_renderDecoration(d));
        }
      }

      // Render elements
      for (final el in slide.elements) {
        final pos = el.position;
        final posStyle = 'left:${pos.x};top:${pos.y};width:${pos.w};height:${pos.h};';

        if (el.type == SlideElementType.image && el.imagePath != null) {
          final imgPath = el.imagePath!.startsWith('asset://') ? 'assets/${el.imagePath!.substring(8)}' : el.imagePath!;
          final imgBytes = _ndfService.readArchiveFileFromBytes(ndfBytes, imgPath);
          if (imgBytes != null) {
            final ext = imgPath.split('.').last.toLowerCase();
            final mime = ext == 'jpg' || ext == 'jpeg' ? 'image/jpeg' : ext == 'svg' ? 'image/svg+xml' : 'image/$ext';
            slidesHtml.write('<div class="slide-el" style="$posStyle"><img src="data:$mime;base64,${base64Encode(imgBytes)}" style="width:100%;height:100%;object-fit:contain;"></div>');
          }
        } else {
          final style = el.style;
          final textStyles = <String>[];
          if (style?.fontSize != null) textStyles.add('font-size:${_scaleFont(style!.fontSize!)}');
          if (style?.color != null) textStyles.add('color:${style!.color}');
          if (style?.bold == true) textStyles.add('font-weight:bold');
          if (style?.italic == true) textStyles.add('font-style:italic');
          if (style?.align != null) textStyles.add('text-align:${style!.align!.name}');
          textStyles.add('font-family:${theme.fonts.heading.family},sans-serif');
          final inlineStyle = textStyles.isNotEmpty ? '${textStyles.join(';')};' : '';

          slidesHtml.write('<div class="slide-el" style="$posStyle$inlineStyle">');
          for (final span in el.content) {
            var text = escapeHtml(span.value);
            if (span.isBold) text = '<strong>$text</strong>';
            if (span.isItalic) text = '<em>$text</em>';
            if (span.isUnderline) text = '<u>$text</u>';
            slidesHtml.write(text);
          }
          slidesHtml.write('</div>');
        }
      }

      slidesHtml.write('<div class="slide-num">${i + 1} / ${slides.length}</div>');
      slidesHtml.write('</div>');
    }

    final hasNotes = slides.any((s) => s.notes.isNotEmpty);
    final contentHtml = '''
      <div class="slide-deck" id="slide-deck">
        $slidesHtml
      </div>
      <div class="slide-nav">
        <button onclick="prevSlide()" id="prev-btn" disabled>\u2190 Prev</button>
        <span class="slide-counter" id="slide-counter">1 / ${slides.length}</span>
        <button onclick="nextSlide()" id="next-btn"${slides.length <= 1 ? ' disabled' : ''}>Next \u2192</button>
        <button onclick="toggleFullscreen()" id="fs-btn" class="slide-fs-btn" title="Fullscreen">
          <svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.5">
            <polyline points="1,6 1,1 6,1"/><polyline points="12,1 17,1 17,6"/>
            <polyline points="17,12 17,17 12,17"/><polyline points="6,17 1,17 1,12"/>
          </svg>
        </button>
      </div>
      ${hasNotes ? '<div class="slide-notes" id="slide-notes"></div>' : ''}''';

    final notesData = hasNotes
        ? slides.map((s) => s.notes.replaceAll("'", "\\'").replaceAll('\n', '\\n')).toList()
        : <String>[];

    final slideScript = '''<script>
(function() {
  var current = 0;
  var total = ${slides.length};
  var slides = document.querySelectorAll('.slide');
  var notes = ${hasNotes ? "[${notesData.map((n) => "'$n'").join(',')}]" : '[]'};
  var notesEl = document.getElementById('slide-notes');
  function showNotes() {
    if (notesEl && notes[current]) { notesEl.innerHTML = '<strong>Notes:</strong> ' + notes[current]; notesEl.style.display = 'block'; }
    else if (notesEl) { notesEl.style.display = 'none'; }
  }
  window.prevSlide = function() {
    if (current > 0) { slides[current].classList.remove('active'); current--; slides[current].classList.add('active'); updateNav(); }
  };
  window.nextSlide = function() {
    if (current < total - 1) { slides[current].classList.remove('active'); current++; slides[current].classList.add('active'); updateNav(); }
  };
  function updateNav() {
    document.getElementById('prev-btn').disabled = current === 0;
    document.getElementById('next-btn').disabled = current === total - 1;
    document.getElementById('slide-counter').textContent = (current + 1) + ' / ' + total;
    showNotes();
  }
  window.toggleFullscreen = function() {
    var deck = document.getElementById('slide-deck');
    if (!deck) return;
    if (document.fullscreenElement) {
      document.exitFullscreen();
    } else {
      deck.requestFullscreen().catch(function() {});
    }
  };
  document.addEventListener('fullscreenchange', function() {
    var d = document.getElementById('slide-deck');
    var btn = document.getElementById('fs-btn');
    if (document.fullscreenElement) {
      d.classList.add('slide-deck--fs');
      d.focus();
      if (btn) btn.title = 'Exit fullscreen';
    } else {
      d.classList.remove('slide-deck--fs');
      if (btn) btn.title = 'Fullscreen';
    }
  });
  // Click on slide deck to enter fullscreen
  var deck = document.getElementById('slide-deck');
  deck.addEventListener('click', function(e) {
    if (!document.fullscreenElement) toggleFullscreen();
  });
  // Make deck focusable so it receives key events in fullscreen
  deck.setAttribute('tabindex', '0');
  deck.style.outline = 'none';
  function handleKey(e) {
    if (e.key === 'ArrowLeft') { prevSlide(); e.preventDefault(); }
    if (e.key === 'ArrowRight') { nextSlide(); e.preventDefault(); }
    if (e.key === 'Escape' && document.fullscreenElement) document.exitFullscreen();
    if (e.key === 'f' || e.key === 'F') toggleFullscreen();
  }
  document.addEventListener('keydown', handleKey);
  deck.addEventListener('keydown', handleKey);
  showNotes();
})();
</script>''';

    return _buildPageShell(
      title: title, ownerIdentifier: ownerIdentifier,
      workspaceName: workspaceName, menuItems: menuItems,
      logo: logo, logoHref: logoHref,
      appStyles: _getPresentationStyles(),
      contentHtml: contentHtml, interaction: interaction,
      likesCount: likesCount, likedHexPubkeys: likedHexPubkeys,
      comments: comments, ownerNpub: ownerNpub,
      documentFilename: documentFilename, extraScripts: slideScript,
      showWorkspaceName: false,
    );
  }

  /// Match theme colors to the closest predefined SlideTemplate.
  SlideTemplate? _matchTemplate(ThemeColors colors) {
    for (final t in SlideTemplate.templates) {
      if (t.colors.primary == colors.primary &&
          t.colors.background == colors.background) {
        return t;
      }
    }
    return null;
  }

  /// Render a template decoration as an absolutely-positioned HTML div.
  String _renderDecoration(SlideDecoration d) {
    final pos = 'left:${d.x};top:${d.y};width:${d.w};height:${d.h};';
    final opacity = d.opacity < 1.0 ? 'opacity:${d.opacity};' : '';
    switch (d.shape) {
      case DecorationShape.rectangle:
        return '<div class="slide-decor" style="${pos}background:${d.color};$opacity"></div>';
      case DecorationShape.circle:
        return '<div class="slide-decor" style="${pos}background:${d.color};border-radius:50%;$opacity"></div>';
      case DecorationShape.gradientBar:
        return '<div class="slide-decor" style="${pos}background:linear-gradient(90deg,${d.color},${d.color2 ?? d.color});$opacity"></div>';
      case DecorationShape.wave:
        return '<div class="slide-decor" style="${pos}background:${d.color};border-radius:50% 50% 0 0;$opacity"></div>';
      case DecorationShape.cornerAccent:
        return '<div class="slide-decor" style="${pos}background:${d.color};clip-path:polygon(0 0,100% 0,100% 100%);$opacity"></div>';
      case DecorationShape.grid:
        final pct = 100 ~/ (d.count ?? 20);
        return '<div class="slide-decor" style="${pos}background:repeating-linear-gradient(0deg,${d.color} 0px,${d.color} 1px,transparent 1px,transparent $pct%),repeating-linear-gradient(90deg,${d.color} 0px,${d.color} 1px,transparent 1px,transparent $pct%);$opacity"></div>';
      case DecorationShape.scanlines:
        final gap = d.count != null && d.count! > 0 ? (100 / d.count!).toStringAsFixed(2) : '1';
        return '<div class="slide-decor" style="${pos}background:repeating-linear-gradient(0deg,${d.color} 0px,${d.color} 1px,transparent 1px,transparent ${gap}%);$opacity"></div>';
      case DecorationShape.diagonalStripes:
        return '<div class="slide-decor" style="${pos}background:repeating-linear-gradient(45deg,${d.color} 0px,${d.color} 2px,transparent 2px,transparent 10px);$opacity"></div>';
      case DecorationShape.dots:
        final sz = 100 ~/ (d.count ?? 4);
        return '<div class="slide-decor" style="${pos}background:radial-gradient(circle,${d.color} 2px,transparent 2px);background-size:${sz}% ${sz}%;$opacity"></div>';
      case DecorationShape.triangle:
        return '<div class="slide-decor" style="${pos}background:${d.color};clip-path:polygon(50% 0,100% 100%,0 100%);$opacity"></div>';
      case DecorationShape.line:
        return '<div class="slide-decor" style="${pos}border-bottom:${d.strokeWidth ?? 2}px solid ${d.color};$opacity"></div>';
    }
  }

  /// Scale font size from slide coordinates (1920px) to responsive CSS.
  String _scaleFont(int slideFontSize) {
    final vw = (slideFontSize / 19.2).toStringAsFixed(1);
    return 'clamp(${(slideFontSize * 0.25).round()}px, ${vw}cqw, ${slideFontSize}px)';
  }

  String _getPresentationStyles() {
    return '''
/* Reduce gap between header and title */
.post-title { margin-top: 0; }
.content { padding-top: 0; }
.header { margin-bottom: 15px; }

.slide-deck {
  position: relative;
  width: 100%;
  aspect-ratio: 16/9;
  border: 1px solid var(--border-color);
  border-radius: 4px;
  overflow: hidden;
  margin-bottom: 12px;
  background: #fff;
  container-type: inline-size;
  cursor: pointer;
}
.slide {
  display: none;
  position: absolute;
  top: 0; left: 0; width: 100%; height: 100%;
}
.slide.active { display: block; }
.slide-el {
  position: absolute;
  overflow: hidden;
  word-wrap: break-word;
  display: flex;
  align-items: flex-start;
  z-index: 1;
}
.slide-decor {
  position: absolute;
  pointer-events: none;
  z-index: 0;
}
.slide-num {
  position: absolute;
  bottom: 8px;
  right: 12px;
  font-size: 11px;
  opacity: 0.3;
  z-index: 2;
}
.slide-nav {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-bottom: 16px;
}
.slide-counter {
  font-size: 0.85rem;
  opacity: 0.6;
  min-width: 60px;
  text-align: center;
}
.slide-nav button {
  background: transparent;
  border: 1px solid var(--border-color);
  color: var(--color);
  padding: 6px 16px;
  border-radius: 4px;
  cursor: pointer;
  font-family: inherit;
  font-size: 0.85rem;
}
.slide-nav button:hover:not(:disabled) { border-color: var(--accent); }
.slide-nav button:disabled { opacity: 0.3; cursor: not-allowed; }
.slide-fs-btn {
  margin-left: auto;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 6px 10px;
}
.slide-fs-btn:hover { color: var(--accent); border-color: var(--accent); }

/* Fullscreen mode */
.slide-deck--fs {
  background: #000;
}
.slide-deck--fs .slide {
  display: flex;
  align-items: center;
  justify-content: center;
}
.slide-deck--fs .slide.active { display: flex; }
.slide-deck--fs .slide-num {
  font-size: 14px;
  opacity: 0.2;
}

.slide-notes {
  display: none;
  padding: 10px 14px;
  margin-bottom: 16px;
  background: var(--accent-alpha-20);
  border-radius: 4px;
  font-size: 0.85rem;
  line-height: 1.5;
}
''' + _getFeedbackStyles() + '''
/* Presentation: extra space before feedback */
.feedback-section { margin-top: 48px; }
.comments-section { margin-top: 48px; }
''';
  }

  // ============================================================
  // TODO viewer (task list with expandable items)
  // ============================================================

  String? _buildTodoPage(Uint8List ndfBytes, {
    required NdfDocument metadata,
    String ownerIdentifier = '', String workspaceName = '',
    String menuItems = '', String logoText = '', String logoHref = '../../',
    NdfInteractionSettings interaction = const NdfInteractionSettings(),
    int likesCount = 0, List<String> likedHexPubkeys = const [],
    List<FeedbackComment> comments = const [], String ownerNpub = '',
    String documentFilename = '',
  }) {
    final mainJson = _ndfService.readArchiveJsonFromBytes(ndfBytes, 'content/main.json');
    if (mainJson == null) return null;

    final content = TodoContent.fromJson(mainJson);
    final title = metadata.title.isNotEmpty ? metadata.title : content.title;
    final logo = logoText.isNotEmpty ? logoText : ownerIdentifier;

    // Read all items
    final items = <TodoItem>[];
    for (final itemId in content.items) {
      final itemJson = _ndfService.readArchiveJsonFromBytes(ndfBytes, 'content/items/$itemId.json');
      if (itemJson != null) {
        try {
          items.add(TodoItem.fromJson(itemJson));
        } catch (_) {}
      }
    }

    // Sort items: pending first, then by priority
    final pending = items.where((i) => !i.isCompleted).toList()
      ..sort((a, b) => a.priority.sortWeight.compareTo(b.priority.sortWeight));
    final completed = items.where((i) => i.isCompleted).toList()
      ..sort((a, b) => (b.completedAt ?? b.createdAt).compareTo(a.completedAt ?? a.createdAt));

    final pendingCount = pending.length;
    final completedCount = completed.length;
    final totalCount = items.length;

    // Build content HTML
    final contentHtml = StringBuffer();

    // Summary bar
    contentHtml.write('<div class="todo-summary">');
    contentHtml.write('<span class="todo-summary-item">');
    contentHtml.write('<span class="todo-count">$totalCount</span> item${totalCount != 1 ? 's' : ''}');
    contentHtml.write('</span>');
    if (pendingCount > 0) {
      contentHtml.write('<span class="todo-summary-item todo-summary-pending">');
      contentHtml.write('<span class="todo-dot todo-dot--pending"></span> $pendingCount pending');
      contentHtml.write('</span>');
    }
    if (completedCount > 0) {
      contentHtml.write('<span class="todo-summary-item todo-summary-done">');
      contentHtml.write('<span class="todo-dot todo-dot--done"></span> $completedCount done');
      contentHtml.write('</span>');
    }
    // Progress bar
    if (totalCount > 0) {
      final pct = (completedCount / totalCount * 100).round();
      contentHtml.write('<span class="todo-progress-wrap">');
      contentHtml.write('<span class="todo-progress-bar"><span class="todo-progress-fill" style="width:$pct%"></span></span>');
      contentHtml.write('<span class="todo-progress-pct">$pct%</span>');
      contentHtml.write('</span>');
    }
    contentHtml.write('</div>');

    if (items.isEmpty) {
      contentHtml.write('<p class="todo-empty">No items in this list</p>');
    } else {
      // Pending items
      if (pending.isNotEmpty) {
        contentHtml.write('<div class="todo-section">');
        for (final item in pending) {
          contentHtml.write(_buildTodoItemHtml(item, ndfBytes));
        }
        contentHtml.write('</div>');
      }

      // Completed items
      if (completed.isNotEmpty && content.settings.showCompleted) {
        contentHtml.write('<div class="todo-section todo-section--completed">');
        contentHtml.write('<div class="todo-section-header" onclick="toggleCompleted()">');
        contentHtml.write('<svg class="todo-chevron" id="todo-chevron" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2"><polyline points="6,4 10,8 6,12"/></svg>');
        contentHtml.write(' Completed ($completedCount)');
        contentHtml.write('</div>');
        contentHtml.write('<div class="todo-completed-list" id="todo-completed-list">');
        for (final item in completed) {
          contentHtml.write(_buildTodoItemHtml(item, ndfBytes));
        }
        contentHtml.write('</div>');
        contentHtml.write('</div>');
      }
    }

    final todoScript = r'''<script>
(function() {
  // Toggle completed section
  window.toggleCompleted = function() {
    var list = document.getElementById('todo-completed-list');
    var chevron = document.getElementById('todo-chevron');
    if (!list) return;
    var hidden = list.style.display === 'none';
    list.style.display = hidden ? 'block' : 'none';
    chevron.style.transform = hidden ? 'rotate(90deg)' : '';
  };

  // Toggle item details
  window.toggleItem = function(id) {
    var details = document.getElementById('details-' + id);
    var chevron = document.getElementById('chevron-' + id);
    if (!details) return;
    var hidden = details.style.display === 'none';
    details.style.display = hidden ? 'block' : 'none';
    chevron.style.transform = hidden ? 'rotate(90deg)' : '';
  };
})();
</script>''';

    return _buildPageShell(
      title: title,
      ownerIdentifier: ownerIdentifier,
      workspaceName: workspaceName,
      menuItems: menuItems,
      logo: logo,
      logoHref: logoHref,
      appStyles: _getTodoStyles(),
      contentHtml: contentHtml.toString(),
      interaction: interaction,
      likesCount: likesCount,
      likedHexPubkeys: likedHexPubkeys,
      comments: comments,
      ownerNpub: ownerNpub,
      documentFilename: documentFilename,
      extraScripts: todoScript,
    );
  }

  String _buildTodoItemHtml(TodoItem item, Uint8List ndfBytes) {
    final buf = StringBuffer();
    final safeId = item.id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    final hasDetails = (item.description != null && item.description!.isNotEmpty) ||
        item.pictures.isNotEmpty || item.links.isNotEmpty || item.updates.isNotEmpty;

    buf.write('<div class="todo-item${item.isCompleted ? ' todo-item--done' : ''}">');

    // Header row
    buf.write('<div class="todo-item-header"${hasDetails ? ' onclick="toggleItem(\'$safeId\')" style="cursor:pointer"' : ''}>');

    // Checkbox icon
    if (item.isCompleted) {
      buf.write('<svg class="todo-check todo-check--done" width="20" height="20" viewBox="0 0 20 20" fill="none">');
      buf.write('<rect x="1" y="1" width="18" height="18" rx="3" fill="var(--accent)" stroke="var(--accent)" stroke-width="1.5"/>');
      buf.write('<polyline points="5,10 8.5,13.5 14.5,6.5" stroke="#fff" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/>');
      buf.write('</svg>');
    } else {
      buf.write('<svg class="todo-check" width="20" height="20" viewBox="0 0 20 20" fill="none">');
      buf.write('<rect x="1" y="1" width="18" height="18" rx="3" stroke="currentColor" stroke-width="1.5"/>');
      buf.write('</svg>');
    }

    // Title
    buf.write('<span class="todo-item-title">${escapeHtml(item.title)}</span>');

    // Badges
    buf.write('<span class="todo-badges">');

    // Priority badge
    if (item.priority != TodoPriority.normal) {
      final (label, cssClass) = switch (item.priority) {
        TodoPriority.high => ('High', 'todo-badge--high'),
        TodoPriority.low => ('Low', 'todo-badge--low'),
        _ => ('', ''),
      };
      buf.write('<span class="todo-badge $cssClass">$label</span>');
    }

    // Duration badge (for completed items)
    if (item.isCompleted && item.durationSummary != null) {
      buf.write('<span class="todo-badge todo-badge--duration">${escapeHtml(item.durationSummary!)}</span>');
    }

    // Attachment indicators
    if (item.pictures.isNotEmpty) {
      buf.write('<span class="todo-badge todo-badge--pictures">${item.pictures.length}</span>');
    }
    if (item.updates.isNotEmpty) {
      buf.write('<span class="todo-badge todo-badge--updates">${item.updates.length}</span>');
    }
    if (item.links.isNotEmpty) {
      buf.write('<span class="todo-badge todo-badge--links">${item.links.length}</span>');
    }

    buf.write('</span>'); // badges

    // Expand chevron
    if (hasDetails) {
      buf.write('<svg class="todo-expand-chevron" id="chevron-$safeId" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2"><polyline points="6,4 10,8 6,12"/></svg>');
    }

    buf.write('</div>'); // header

    // Expandable details
    if (hasDetails) {
      buf.write('<div class="todo-item-details" id="details-$safeId" style="display:none">');

      // Description
      if (item.description != null && item.description!.isNotEmpty) {
        buf.write('<p class="todo-item-desc">${escapeHtml(item.description!)}</p>');
      }

      // Pictures
      if (item.pictures.isNotEmpty) {
        buf.write('<div class="todo-pictures">');
        for (final picPath in item.pictures) {
          final picBytes = _ndfService.readArchiveFileFromBytes(ndfBytes, 'assets/$picPath');
          if (picBytes != null) {
            final ext = picPath.split('.').last.toLowerCase();
            final mime = ext == 'png' ? 'image/png'
                : ext == 'gif' ? 'image/gif'
                : ext == 'webp' ? 'image/webp'
                : 'image/jpeg';
            buf.write('<img class="todo-picture" src="data:$mime;base64,${base64Encode(picBytes)}" alt="">');
          }
        }
        buf.write('</div>');
      }

      // Updates
      if (item.updates.isNotEmpty) {
        buf.write('<div class="todo-updates">');
        for (final update in item.updates) {
          buf.write('<div class="todo-update">');
          buf.write('<span class="todo-update-date">${_formatTodoDate(update.createdAt)}</span>');
          buf.write('<span class="todo-update-text">${escapeHtml(update.content)}</span>');
          buf.write('</div>');
        }
        buf.write('</div>');
      }

      // Links
      if (item.links.isNotEmpty) {
        buf.write('<div class="todo-links">');
        for (final link in item.links) {
          buf.write('<a class="todo-link" href="${escapeHtml(link.url)}" target="_blank" rel="noopener">');
          buf.write('<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M6.5 3.5H3a1 1 0 0 0-1 1V13a1 1 0 0 0 1 1h8.5a1 1 0 0 0 1-1V9.5"/><path d="M9.5 2h4.5v4.5"/><line x1="14" y1="2" x2="7.5" y2="8.5"/></svg>');
          buf.write(' ${escapeHtml(link.title.isNotEmpty ? link.title : link.url)}');
          buf.write('</a>');
        }
        buf.write('</div>');
      }

      buf.write('</div>'); // details
    }

    buf.write('</div>'); // todo-item
    return buf.toString();
  }

  String _formatTodoDate(DateTime dt) {
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '${dt.year}-$m-$d $h:$min';
  }

  String _getTodoStyles() {
    return '''
/* TODO summary */
.todo-summary {
  display: flex; flex-wrap: wrap; align-items: center; gap: 12px;
  padding: 10px 14px;
  background: var(--accent-alpha-20);
  border: 1px solid var(--border-color);
  border-radius: 8px;
  font-size: 0.85rem;
  margin-bottom: 16px;
}
.todo-summary-item { display: flex; align-items: center; gap: 5px; }
.todo-count { font-weight: bold; }
.todo-dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; }
.todo-dot--pending { background: var(--accent); }
.todo-dot--done { background: #4caf50; }
.todo-progress-wrap { display: flex; align-items: center; gap: 6px; margin-left: auto; }
.todo-progress-bar { width: 80px; height: 6px; background: var(--border-color); border-radius: 3px; overflow: hidden; }
.todo-progress-fill { height: 100%; background: #4caf50; border-radius: 3px; transition: width 0.3s; }
.todo-progress-pct { font-size: 0.8rem; font-weight: bold; opacity: 0.7; }
.todo-empty { opacity: 0.5; font-style: italic; }

/* Items */
.todo-section { margin-bottom: 16px; }
.todo-section--completed { margin-top: 8px; }
.todo-section-header {
  font-size: 0.85rem; font-weight: bold; opacity: 0.6;
  cursor: pointer; display: flex; align-items: center; gap: 4px;
  padding: 6px 0; user-select: none;
}
.todo-section-header:hover { opacity: 1; }
.todo-chevron { transition: transform 0.15s; transform: rotate(90deg); }
.todo-item {
  border: 1px solid var(--border-color);
  border-radius: 8px;
  margin-bottom: 8px;
  transition: border-color 0.15s;
}
.todo-item:hover { border-color: var(--accent); }
.todo-item--done { opacity: 0.65; }
.todo-item-header {
  display: flex; align-items: center; gap: 10px;
  padding: 10px 12px;
}
.todo-check { flex-shrink: 0; opacity: 0.5; }
.todo-check--done { opacity: 1; }
.todo-item-title {
  flex: 1; min-width: 0;
  font-weight: 500;
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
.todo-item--done .todo-item-title { text-decoration: line-through; opacity: 0.7; }
.todo-badges { display: flex; gap: 6px; flex-shrink: 0; align-items: center; }
.todo-badge {
  display: inline-flex; align-items: center; gap: 3px;
  padding: 2px 7px;
  border-radius: 4px;
  font-size: 0.7rem; font-weight: 600;
  white-space: nowrap;
}
.todo-badge--high { background: rgba(244,67,54,0.15); color: #f44336; }
.todo-badge--low { background: rgba(158,158,158,0.15); color: #9e9e9e; }
.todo-badge--duration { background: rgba(76,175,80,0.15); color: #4caf50; }
.todo-badge--pictures { background: rgba(33,150,243,0.15); color: #2196f3; }
.todo-badge--pictures::before { content: "\\1F4F7"; font-size: 0.65rem; }
.todo-badge--updates { background: rgba(255,152,0,0.15); color: #ff9800; }
.todo-badge--updates::before { content: "\\1F4DD"; font-size: 0.65rem; }
.todo-badge--links { background: rgba(156,39,176,0.15); color: #9c27b0; }
.todo-badge--links::before { content: "\\1F517"; font-size: 0.65rem; }
.todo-expand-chevron {
  flex-shrink: 0; opacity: 0.4;
  transition: transform 0.15s;
}
.todo-item:hover .todo-expand-chevron { opacity: 0.8; }

/* Expandable details */
.todo-item-details {
  padding: 0 12px 12px 42px;
  border-top: 1px solid var(--border-color);
}
.todo-item-desc {
  margin: 10px 0;
  font-size: 0.9rem;
  line-height: 1.6;
  opacity: 0.85;
}
.todo-pictures {
  display: flex; flex-wrap: wrap; gap: 8px;
  margin: 8px 0;
}
.todo-picture {
  width: 80px; height: 80px;
  object-fit: cover;
  border-radius: 6px;
  border: 1px solid var(--border-color);
}
.todo-updates { margin: 8px 0; }
.todo-update {
  display: flex; flex-direction: column;
  padding: 8px 10px;
  margin-bottom: 6px;
  background: var(--accent-alpha-20);
  border-radius: 6px;
  font-size: 0.85rem;
}
.todo-update-date { font-size: 0.7rem; opacity: 0.5; margin-bottom: 3px; }
.todo-update-text { line-height: 1.5; }
.todo-links { display: flex; flex-direction: column; gap: 4px; margin: 8px 0; }
.todo-link {
  display: inline-flex; align-items: center; gap: 5px;
  color: var(--accent);
  text-decoration: none;
  font-size: 0.85rem;
}
.todo-link:hover { text-decoration: underline; }
''' + _getFeedbackStyles() + '''
''';
  }

  // ============================================================
  // Voice memo viewer (meeting recordings design with audio playback)
  // ============================================================

  String? _buildVoiceMemoPage(Uint8List ndfBytes, {
    required NdfDocument metadata,
    String ownerIdentifier = '', String workspaceName = '',
    String menuItems = '', String logoText = '', String logoHref = '../../',
    NdfInteractionSettings interaction = const NdfInteractionSettings(),
    int likesCount = 0, List<String> likedHexPubkeys = const [],
    List<FeedbackComment> comments = const [], String ownerNpub = '',
    String documentFilename = '',
  }) {
    final mainJson = _ndfService.readArchiveJsonFromBytes(ndfBytes, 'content/main.json');
    if (mainJson == null) return null;

    final content = VoiceMemoContent.fromJson(mainJson);
    final title = metadata.title.isNotEmpty ? metadata.title : content.title;
    final logo = logoText.isNotEmpty ? logoText : ownerIdentifier;

    // Read all clips
    final clips = <VoiceMemoClip>[];
    for (final clipId in content.clips) {
      final clipJson = _ndfService.readArchiveJsonFromBytes(ndfBytes, 'content/clips/$clipId.json');
      if (clipJson != null) {
        try {
          clips.add(VoiceMemoClip.fromJson(clipJson));
        } catch (_) {}
      }
    }

    // Build clips HTML — meeting recording card design with audio playback
    final contentHtml = StringBuffer();
    if (clips.isEmpty) {
      contentHtml.write('<p style="opacity:0.5">No clips in this voice memo</p>');
    } else {
      contentHtml.write('<div class="vm-count">${clips.length} clip${clips.length != 1 ? 's' : ''}</div>');
      contentHtml.write('<div class="vm-clips">');
      for (var i = 0; i < clips.length; i++) {
        final clip = clips[i];
        final audioPath = 'assets/${clip.audioFile}';
        final audioBytes = _ndfService.readArchiveFileFromBytes(ndfBytes, audioPath);
        final ext = clip.audioFile.split('.').last.toLowerCase();
        final audioMime = ext == 'ogg' ? 'audio/ogg'
            : ext == 'mp3' ? 'audio/mpeg'
            : ext == 'wav' ? 'audio/wav'
            : ext == 'webm' ? 'audio/webm'
            : ext == 'm4a' ? 'audio/mp4'
            : 'audio/ogg';
        final hasAudio = audioBytes != null;
        final clipId = 'clip-$i';
        final hasTranscript = clip.transcription != null && content.settings.showTranscriptions;

        contentHtml.write('<div class="vm-wrapper">');
        contentHtml.write('<a class="vm-asset${i == 0 && hasAudio ? ' vm-asset--active' : ''}" href="#" onclick="playClip(\'$clipId\',event)" id="$clipId-card">');

        // Play/pause icon (circle + triangle, matching meeting recording design)
        contentHtml.write('<svg class="vm-play-icon" id="$clipId-icon" width="36" height="36" viewBox="0 0 36 36" fill="none">');
        contentHtml.write('<circle cx="18" cy="18" r="17" stroke="currentColor" stroke-width="1.5"/>');
        contentHtml.write('<polygon points="14,11 14,25 26,18" fill="currentColor"/>');
        contentHtml.write('</svg>');

        contentHtml.write('<div class="vm-info">');
        contentHtml.write('<div class="vm-asset-title">${escapeHtml(clip.title)}</div>');
        contentHtml.write('<div class="vm-asset-meta">${clip.durationFormatted}');
        if (clip.description != null && clip.description!.isNotEmpty) {
          contentHtml.write(' \u00B7 ${escapeHtml(clip.description!)}');
        }
        contentHtml.write('</div>');
        contentHtml.write('</div>');

        if (hasTranscript) {
          contentHtml.write('<button class="vm-transcript-btn" onclick="toggleTranscript(\'$clipId\',event)" title="Transcript">');
          contentHtml.write('<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.2"><rect x="2" y="2" width="12" height="12" rx="1.5"/><line x1="4.5" y1="5" x2="11.5" y2="5"/><line x1="4.5" y1="8" x2="11.5" y2="8"/><line x1="4.5" y1="11" x2="8.5" y2="11"/></svg>');
          contentHtml.write('</button>');
        }

        contentHtml.write('</a>');

        // Progress bar + time + equalizer (hidden until playing)
        if (hasAudio) {
          contentHtml.write('<div class="vm-player" id="$clipId-player" style="display:none">');
          // Equalizer bars (same pattern as meeting volume meter)
          contentHtml.write('<div class="vm-meter" id="$clipId-meter">');
          for (var b = 0; b < 20; b++) {
            contentHtml.write('<div class="vm-meter-bar"></div>');
          }
          contentHtml.write('</div>');
          // Seek slider + time
          contentHtml.write('<div class="vm-seek-row">');
          contentHtml.write('<span class="vm-time" id="$clipId-time">0:00</span>');
          contentHtml.write('<input type="range" class="vm-slider" id="$clipId-slider" min="0" max="1000" value="0">');
          contentHtml.write('<span class="vm-time" id="$clipId-dur">${clip.durationFormatted}</span>');
          contentHtml.write('</div>');
          contentHtml.write('</div>');
          contentHtml.write('<audio id="$clipId-audio" src="data:$audioMime;base64,${base64Encode(audioBytes)}" preload="none"></audio>');
        }

        if (hasTranscript) {
          contentHtml.write('<div class="vm-transcript" id="$clipId-transcript" style="display:none">${escapeHtml(clip.transcription!.text)}</div>');
        }

        contentHtml.write('</div>');
      }
      contentHtml.write('</div>');
    }

    final audioScript = r'''<script>
(function() {
  var currentAudio = null, currentCard = null, currentClipId = null;
  var progressTimer = null, meterTimer = null;
  var seeking = false;

  function fmt(s) {
    if (isNaN(s) || !isFinite(s)) return '0:00';
    var m = Math.floor(s / 60), sec = Math.floor(s % 60);
    return m + ':' + (sec < 10 ? '0' : '') + sec;
  }

  function showPlayer(id, show) {
    var player = document.getElementById(id + '-player');
    if (player) player.style.display = show ? 'block' : 'none';
  }

  function startProgress(id) {
    stopProgress();
    var audio = document.getElementById(id + '-audio');
    var slider = document.getElementById(id + '-slider');
    var timeEl = document.getElementById(id + '-time');
    var durEl = document.getElementById(id + '-dur');
    if (!audio || !slider) return;
    // Set duration text once loaded
    if (audio.duration && isFinite(audio.duration)) durEl.textContent = fmt(audio.duration);
    audio.addEventListener('loadedmetadata', function() { durEl.textContent = fmt(audio.duration); });
    progressTimer = setInterval(function() {
      if (!seeking && audio.duration) {
        slider.value = Math.floor((audio.currentTime / audio.duration) * 1000);
        timeEl.textContent = fmt(audio.currentTime);
      }
    }, 200);
    // Seek events
    slider.oninput = function() { seeking = true; };
    slider.onchange = function() {
      if (audio.duration) audio.currentTime = (slider.value / 1000) * audio.duration;
      seeking = false;
    };
  }

  function stopProgress() {
    if (progressTimer) { clearInterval(progressTimer); progressTimer = null; }
  }

  // Equalizer meter animation (reuses meeting volume-meter pattern)
  function startMeter(id) {
    stopMeter();
    var meter = document.getElementById(id + '-meter');
    if (!meter) return;
    var bars = meter.children;
    meterTimer = setInterval(function() {
      // Shift bars left
      for (var i = 0; i < bars.length - 1; i++) {
        bars[i].style.height = bars[i + 1].style.height;
        bars[i].style.opacity = bars[i + 1].style.opacity;
      }
      // Random level for last bar (simulated from playback)
      var h = 0.15 + Math.random() * 0.85;
      var last = bars[bars.length - 1];
      last.style.height = Math.max(2, h * 20) + 'px';
      last.style.opacity = String(0.3 + h * 0.7);
    }, 120);
  }

  function stopMeter() {
    if (meterTimer) { clearInterval(meterTimer); meterTimer = null; }
  }

  function resetMeter(id) {
    var meter = document.getElementById(id + '-meter');
    if (!meter) return;
    var bars = meter.children;
    for (var i = 0; i < bars.length; i++) {
      bars[i].style.height = '2px';
      bars[i].style.opacity = '0.3';
    }
  }

  function setIcon(id, playing) {
    var svg = document.getElementById(id + '-icon');
    if (!svg) return;
    svg.innerHTML = playing
      ? '<circle cx="18" cy="18" r="17" stroke="currentColor" stroke-width="1.5"/><rect x="12" y="11" width="4" height="14" rx="1" fill="currentColor"/><rect x="20" y="11" width="4" height="14" rx="1" fill="currentColor"/>'
      : '<circle cx="18" cy="18" r="17" stroke="currentColor" stroke-width="1.5"/><polygon points="14,11 14,25 26,18" fill="currentColor"/>';
  }

  function stopAll() {
    if (currentAudio) {
      currentAudio.pause(); currentAudio.currentTime = 0;
    }
    if (currentCard) currentCard.classList.remove('vm-asset--active');
    if (currentClipId) {
      setIcon(currentClipId, false);
      showPlayer(currentClipId, false);
      resetMeter(currentClipId);
    }
    stopProgress(); stopMeter();
    currentAudio = null; currentCard = null; currentClipId = null;
  }

  window.playClip = function(id, e) {
    e.preventDefault();
    var audio = document.getElementById(id + '-audio');
    var card = document.getElementById(id + '-card');
    if (!audio) return;

    if (currentAudio && currentAudio !== audio) stopAll();

    if (audio.paused) {
      audio.play(); currentAudio = audio; currentCard = card; currentClipId = id;
      card.classList.add('vm-asset--active');
      setIcon(id, true);
      showPlayer(id, true);
      startProgress(id);
      startMeter(id);
    } else {
      audio.pause();
      setIcon(id, false);
      stopProgress(); stopMeter();
    }

    audio.onended = function() {
      setIcon(id, false);
      card.classList.remove('vm-asset--active');
      showPlayer(id, false);
      resetMeter(id);
      stopProgress(); stopMeter();
      // Reset slider
      var slider = document.getElementById(id + '-slider');
      if (slider) slider.value = 0;
      var timeEl = document.getElementById(id + '-time');
      if (timeEl) timeEl.textContent = '0:00';
      currentAudio = null; currentCard = null; currentClipId = null;
    };
  };

  window.toggleTranscript = function(id, e) {
    e.preventDefault(); e.stopPropagation();
    var panel = document.getElementById(id + '-transcript');
    if (!panel) return;
    var open = panel.style.display !== 'none';
    panel.style.display = open ? 'none' : 'block';
    e.currentTarget.classList.toggle('vm-transcript-btn--open', !open);
  };
})();
</script>''';

    return _buildPageShell(
      title: title, ownerIdentifier: ownerIdentifier,
      workspaceName: workspaceName, menuItems: menuItems,
      logo: logo, logoHref: logoHref,
      appStyles: _getVoiceMemoStyles(),
      contentHtml: contentHtml.toString(), interaction: interaction,
      likesCount: likesCount, likedHexPubkeys: likedHexPubkeys,
      comments: comments, ownerNpub: ownerNpub,
      documentFilename: documentFilename, extraScripts: audioScript,
    );
  }

  String _getVoiceMemoStyles() {
    return '''
.vm-count { font-size: 0.85rem; opacity: 0.6; margin-bottom: 12px; }
.vm-clips { display: flex; flex-direction: column; gap: 10px; }
.vm-asset {
  display: flex; align-items: center; gap: 12px;
  padding: 10px 12px;
  border: 1px solid var(--border-color);
  border-radius: 10px;
  color: inherit; text-decoration: none; cursor: pointer;
  transition: border-color 0.15s;
}
.vm-asset:hover { border-color: var(--accent); color: var(--accent); }
.vm-asset--active { border-color: var(--accent); background: var(--accent-alpha-20); }
.vm-play-icon { flex-shrink: 0; color: var(--accent); }
.vm-info { flex: 1; min-width: 0; }
.vm-asset-title { font-weight: bold; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.vm-asset-meta { font-size: 0.8rem; opacity: 0.6; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.vm-transcript-btn {
  flex-shrink: 0; background: none; border: none; color: inherit;
  opacity: 0.5; padding: 4px; cursor: pointer; display: flex; align-items: center;
}
.vm-transcript-btn:hover { opacity: 1; }
.vm-transcript-btn--open { opacity: 1; color: var(--accent); }
.vm-transcript { padding: 8px 12px; font-size: 0.85rem; white-space: pre-wrap; color: var(--accent-alpha-70); line-height: 1.6; }

/* Audio player: meter + seek slider */
.vm-player {
  padding: 6px 12px 8px;
  margin-top: -1px;
  border: 1px solid var(--accent-alpha-70);
  border-top: none;
  border-radius: 0 0 10px 10px;
  background: var(--accent-alpha-20);
}
.vm-meter {
  display: flex;
  align-items: flex-end;
  gap: 2px;
  height: 20px;
  width: 100%;
  margin-bottom: 6px;
}
.vm-meter-bar {
  flex: 1;
  min-width: 2px;
  height: 2px;
  background: var(--accent);
  border-radius: 1px;
  opacity: 0.3;
  transition: height 100ms ease-out, opacity 100ms ease-out;
}
.vm-seek-row {
  display: flex;
  align-items: center;
  gap: 8px;
}
.vm-time {
  font-size: 0.7rem;
  font-family: monospace;
  opacity: 0.6;
  min-width: 32px;
  text-align: center;
}
.vm-slider {
  flex: 1;
  -webkit-appearance: none;
  appearance: none;
  height: 4px;
  background: var(--border-color);
  border-radius: 2px;
  outline: none;
  cursor: pointer;
}
.vm-slider::-webkit-slider-thumb {
  -webkit-appearance: none;
  width: 12px;
  height: 12px;
  border-radius: 50%;
  background: var(--accent);
  cursor: pointer;
}
.vm-slider::-moz-range-thumb {
  width: 12px;
  height: 12px;
  border-radius: 50%;
  background: var(--accent);
  border: none;
  cursor: pointer;
}
''' + _getFeedbackStyles() + '''
''';
  }

  // ============================================================
  // Shared feedback styles (used by all NDF viewer types)
  // ============================================================

  String _getFeedbackStyles() {
    return '''
/* Feedback section */
.feedback-section {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-top: 20px;
  padding-top: 15px;
  border-top: 1px solid var(--border-color);
}
.like-button {
  display: flex;
  align-items: center;
  gap: 6px;
  background: transparent;
  border: 1px solid var(--border-color);
  border-radius: 4px;
  padding: 6px 14px;
  color: var(--color);
  cursor: pointer;
  font-family: inherit;
  font-size: 0.9rem;
  transition: border-color 0.15s;
}
.like-button:hover { border-color: var(--accent); }
.like-button.liked { color: #e25555; border-color: #e25555; }
.like-count { font-size: 0.85rem; opacity: 0.7; }

/* Comments */
.comments-section {
  margin-top: 24px;
  padding-top: 15px;
  border-top: 1px solid var(--border-color);
}
.comments-section h3 { margin: 0 0 12px; }
.comment {
  padding: 10px 0;
  border-bottom: 1px solid var(--border-color);
}
.comment-meta {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 0.8rem;
  margin-bottom: 4px;
}
.comment-author { color: var(--accent); font-weight: bold; }
.comment-date { opacity: 0.5; }
.comment-delete {
  background: none;
  border: none;
  color: var(--color);
  opacity: 0.4;
  cursor: pointer;
  font-size: 0.8rem;
  padding: 0 4px;
  margin-left: auto;
}
.comment-delete:hover { opacity: 1; color: #e25555; }
.comment p { margin: 0; font-size: 0.9rem; }
.comment-form { margin-top: 16px; }
.comment-form textarea {
  width: 100%;
  background: var(--background);
  color: var(--color);
  border: 1px solid var(--border-color);
  border-radius: 4px;
  padding: 8px;
  font-family: inherit;
  font-size: 0.9rem;
  resize: vertical;
}
.comment-form button {
  margin-top: 8px;
  background: var(--accent);
  color: #000;
  border: none;
  border-radius: 4px;
  padding: 6px 16px;
  cursor: pointer;
  font-family: inherit;
  font-size: 0.85rem;
}
.comment-form button:hover { opacity: 0.9; }
.comment-form button:disabled { opacity: 0.5; cursor: not-allowed; }
''';
  }

  // ============================================================
  // Spreadsheet helpers
  // ============================================================

  /// Build an HTML table for a single sheet.
  String _buildSheetTable(SpreadsheetSheet sheet) {
    final buf = StringBuffer();

    // Determine actual data bounds (cap at 500 rows)
    final maxRow = _getMaxRow(sheet).clamp(0, 499);
    final maxCol = _getMaxCol(sheet).clamp(0, 51); // cap at AZ

    // Build merge map
    final mergeMap = _buildMergeMap(sheet);

    buf.write('<div class="sheet-table-wrapper"><table class="sheet-table">');

    // Colgroup for column widths (matching Flutter UI defaults)
    buf.write('<colgroup>');
    buf.write('<col style="width:${_rowHeaderWidth}px">'); // row header
    for (var c = 0; c <= maxCol; c++) {
      final w = sheet.columns[c]?.width ?? _defaultColWidth;
      buf.write('<col style="width:${w.toInt()}px">');
    }
    buf.write('</colgroup>');

    // Column headers
    buf.write('<thead><tr><th class="hdr corner-hdr"></th>');
    for (var c = 0; c <= maxCol; c++) {
      final frozen = c < sheet.frozenCols ? ' frozen-col' : '';
      buf.write(
        '<th class="hdr col-hdr$frozen">'
        '${SpreadsheetSheet.columnLetter(c)}</th>',
      );
    }
    buf.write('</tr></thead>');

    // Data rows
    buf.write('<tbody>');
    for (var r = 0; r <= maxRow; r++) {
      final frozenRow = r < sheet.frozenRows;
      buf.write('<tr>');
      buf.write(
        '<td class="hdr row-hdr${frozenRow ? ' frozen-row' : ''}">${r + 1}</td>',
      );
      for (var c = 0; c <= maxCol; c++) {
        final key = '$r:$c';
        final mergeInfo = mergeMap[key];

        // Skip cells covered by a merge
        if (mergeInfo != null && mergeInfo.skip) continue;

        final cell = sheet.cells[key];
        final styleName = cell?.style;
        final cellStyle = styleName != null ? sheet.styles[styleName] : null;

        final cssClasses = <String>[];
        if (frozenRow) cssClasses.add('frozen-row');
        if (c < sheet.frozenCols) cssClasses.add('frozen-col');

        final inlineStyle = _cellInlineStyle(cellStyle);

        final spanAttrs = StringBuffer();
        if (mergeInfo != null) {
          if (mergeInfo.colspan > 1) {
            spanAttrs.write(' colspan="${mergeInfo.colspan}"');
          }
          if (mergeInfo.rowspan > 1) {
            spanAttrs.write(' rowspan="${mergeInfo.rowspan}"');
          }
        }

        final displayValue = cell?.displayValue ?? '';
        final classAttr =
            cssClasses.isNotEmpty ? ' class="${cssClasses.join(' ')}"' : '';

        buf.write(
          '<td$classAttr$spanAttrs${inlineStyle.isNotEmpty ? ' style="$inlineStyle"' : ''}>'
          '${escapeHtml(displayValue)}</td>',
        );
      }
      buf.write('</tr>');
    }
    buf.write('</tbody></table></div>');

    // Large sheet notice
    final totalRows = _getMaxRow(sheet);
    if (totalRows > 499) {
      buf.write(
        '<p class="sheet-notice">Showing first 500 of ${totalRows + 1} rows</p>',
      );
    }

    return buf.toString();
  }

  int _getMaxRow(SpreadsheetSheet sheet) {
    int maxRow = 0;
    for (final key in sheet.cells.keys) {
      final parts = key.split(':');
      if (parts.length == 2) {
        final r = int.tryParse(parts[0]);
        if (r != null && r > maxRow) maxRow = r;
      }
    }
    return maxRow;
  }

  int _getMaxCol(SpreadsheetSheet sheet) {
    int maxCol = 0;
    for (final key in sheet.cells.keys) {
      final parts = key.split(':');
      if (parts.length == 2) {
        final c = int.tryParse(parts[1]);
        if (c != null && c > maxCol) maxCol = c;
      }
    }
    return maxCol;
  }

  Map<String, _MergeInfo> _buildMergeMap(SpreadsheetSheet sheet) {
    final map = <String, _MergeInfo>{};
    for (final merge in sheet.merges) {
      final startParts = merge.start.split(':');
      final endParts = merge.end.split(':');
      if (startParts.length != 2 || endParts.length != 2) continue;

      final startRow = int.tryParse(startParts[0]);
      final startCol = int.tryParse(startParts[1]);
      final endRow = int.tryParse(endParts[0]);
      final endCol = int.tryParse(endParts[1]);
      if (startRow == null ||
          startCol == null ||
          endRow == null ||
          endCol == null) {
        continue;
      }

      final rowspan = endRow - startRow + 1;
      final colspan = endCol - startCol + 1;

      map['$startRow:$startCol'] =
          _MergeInfo(colspan: colspan, rowspan: rowspan);

      for (var r = startRow; r <= endRow; r++) {
        for (var c = startCol; c <= endCol; c++) {
          if (r == startRow && c == startCol) continue;
          map['$r:$c'] = _MergeInfo.covered();
        }
      }
    }
    return map;
  }

  String _cellInlineStyle(CellStyle? style) {
    if (style == null) return '';
    final parts = <String>[];
    if (style.bold == true) parts.add('font-weight:bold');
    if (style.italic == true) parts.add('font-style:italic');
    if (style.fontSize != null) parts.add('font-size:${style.fontSize}px');
    if (style.textColor != null) parts.add('color:${style.textColor}');
    if (style.backgroundColor != null) {
      parts.add('background-color:${style.backgroundColor}');
    }
    if (style.alignment != null) {
      final h = style.alignment!['horizontal'] as String?;
      if (h != null) parts.add('text-align:$h');
      final v = style.alignment!['vertical'] as String?;
      if (v != null) parts.add('vertical-align:$v');
    }
    return parts.join(';');
  }

  String _getSpreadsheetStyles() {
    return '''
/* Sheet tabs */
.sheet-tabs {
  display: flex;
  gap: 2px;
  margin-bottom: 12px;
  border-bottom: 1px solid var(--border-color);
}
.sheet-tab {
  padding: 6px 16px;
  border: 1px solid var(--border-color);
  border-bottom: none;
  background: transparent;
  color: var(--color);
  cursor: pointer;
  font-family: inherit;
  font-size: 0.85rem;
  border-radius: 4px 4px 0 0;
  opacity: 0.6;
  transition: opacity 0.15s;
}
.sheet-tab:hover { opacity: 1; }
.sheet-tab.active {
  opacity: 1;
  color: var(--accent);
  border-color: var(--accent-alpha-70);
  background: var(--background);
  position: relative;
  bottom: -1px;
  padding-bottom: 7px;
}
.sheet-panel { display: none; }
.sheet-panel.active { display: block; }

/* Table wrapper — scroll horizontally within the container */
.sheet-table-wrapper {
  overflow-x: auto;
  margin-bottom: 20px;
  border: 1px solid var(--border-color);
  border-radius: 3px;
}
.sheet-table {
  border-collapse: collapse;
  font-size: 13px;
  line-height: 1.4;
  white-space: nowrap;
  table-layout: fixed;
}
.sheet-table th,
.sheet-table td {
  border: 1px solid var(--border-color);
  padding: 2px 6px;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* Headers — subtle, not flashy */
.hdr {
  background: var(--background);
  color: var(--accent-alpha-70);
  font-weight: normal;
  font-size: 11px;
  text-align: center;
  user-select: none;
}
.col-hdr {
  position: sticky;
  top: 0;
  z-index: 2;
  border-bottom: 2px solid var(--border-color);
}
.row-hdr {
  position: sticky;
  left: 0;
  z-index: 1;
  border-right: 2px solid var(--border-color);
}
.corner-hdr {
  position: sticky;
  top: 0;
  left: 0;
  z-index: 3;
  border-right: 2px solid var(--border-color);
  border-bottom: 2px solid var(--border-color);
}

/* Frozen visual distinction — thin accent line */
.frozen-row { border-bottom: 2px solid var(--accent-alpha-70); }
.frozen-col { border-right: 2px solid var(--accent-alpha-70); }

.sheet-notice {
  opacity: 0.5;
  font-size: 0.8rem;
  margin-top: 8px;
}

/* Override container max-width for wide spreadsheets */
@media (min-width: 900px) {
  .container { max-width: 95vw; }
}

''' + _getFeedbackStyles() + '''
''';
  }

  String _getTabScript() {
    return '''
function switchSheet(id) {
  document.querySelectorAll('.sheet-panel').forEach(function(p) {
    p.classList.remove('active');
  });
  document.querySelectorAll('.sheet-tab').forEach(function(t) {
    t.classList.remove('active');
  });
  var panel = document.getElementById(id);
  if (panel) panel.classList.add('active');
  var tabs = document.querySelectorAll('.sheet-tab');
  for (var i = 0; i < tabs.length; i++) {
    if (tabs[i].getAttribute('onclick').indexOf(id) !== -1) {
      tabs[i].classList.add('active');
      break;
    }
  }
}
''';
  }

  String _buildFeedbackHtml(
    NdfInteractionSettings interaction,
    int likesCount,
    List<FeedbackComment> comments,
  ) {
    if (!interaction.hasAnyInteraction) return '';
    final buf = StringBuffer();

    // Likes section (hidden until Nostr connects — same as blog)
    if (interaction.permitLikes) {
      buf.write('''
      <div class="feedback-section" id="feedback-section" style="display: none;">
        <button class="like-button" id="like-button" onclick="toggleLike()">
          <span id="like-icon">\u2661</span>
          <span>Like</span>
        </button>
        <span class="like-count" id="like-count">${likesCount > 0 ? "$likesCount like${likesCount != 1 ? "s" : ""}" : ""}</span>
      </div>''');
    }

    // Comments section
    if (interaction.permitComments) {
      buf.write('<div class="comments-section" id="comments-section">');
      buf.write('<h3>Comments${comments.isNotEmpty ? " (${comments.length})" : ""}</h3>');

      for (final c in comments) {
        buf.write('''
        <div class="comment" data-comment-id="${escapeHtml(c.id)}" data-comment-npub="${escapeHtml(c.npub ?? '')}">
          <div class="comment-meta">
            <span class="comment-author">${escapeHtml(c.author)}</span>
            <span class="comment-date">${escapeHtml(c.created)}</span>
            <button class="comment-delete" onclick="deleteComment('${escapeHtml(c.id)}')" style="display:none" title="Delete">\u2715</button>
          </div>
          <p>${escapeHtml(c.content)}</p>
        </div>''');
      }

      // Comment form (hidden until Nostr connects)
      buf.write('''
      <div class="comment-form" id="comment-form" style="display: none;">
        <textarea id="comment-input" placeholder="Write a comment..." rows="3"></textarea>
        <button id="comment-submit" onclick="submitComment()">Post Comment</button>
      </div>''');
      buf.write('</div>');
    }

    return buf.toString();
  }

  String _getLikesScript(String authorNpub, int likesCount, List<String> likedHexPubkeys, String filename) {
    // Use the filename as the base for API URLs since the browser treats .ndf as a file
    // From page at .../Spreadsheet%202.ndf, we need "Spreadsheet%202.ndf/like"
    final encodedFilename = Uri.encodeComponent(filename);
    return '''
<script>
(function() {
  const authorNpub = '${escapeHtml(authorNpub)}';
  const likedPubkeys = ${toJsonArray(likedHexPubkeys)};
  const apiBase = '$encodedFilename';
  let userPubkey = null;
  let isLiked = false;

  function onNostrConnected(pubkey) {
    userPubkey = pubkey;
    var sec = document.getElementById('feedback-section');
    if (sec) sec.style.display = 'flex';
    if (likedPubkeys.includes(pubkey)) {
      isLiked = true;
      updateUI($likesCount);
    }
  }

  function init() {
    document.addEventListener('nostr-connected', function(e) {
      onNostrConnected(e.detail.pubkey);
    });
    if (window.GeogramNostr && window.GeogramNostr.connected && window.GeogramNostr.pubkey) {
      onNostrConnected(window.GeogramNostr.pubkey);
    }
  }

  window.toggleLike = async function() {
    if (!userPubkey || !window.nostr) { alert('Please connect with Nostr first'); return; }
    var button = document.getElementById('like-button');
    button.disabled = true;
    try {
      var unsignedEvent = {
        pubkey: userPubkey,
        created_at: Math.floor(Date.now() / 1000),
        kind: 7,
        tags: [['p', authorNpub], ['type', 'likes']],
        content: 'like'
      };
      var signedEvent = await window.nostr.signEvent(unsignedEvent);
      if (!signedEvent || !signedEvent.sig) throw new Error('Signing failed');
      var response = await fetch(apiBase + '/like', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(signedEvent)
      });
      var result = await response.json();
      if (result.success) { isLiked = result.liked; updateUI(result.like_count); }
    } catch (e) { console.error('Like error:', e); }
    finally { button.disabled = false; }
  };

  function updateUI(count) {
    var button = document.getElementById('like-button');
    var icon = document.getElementById('like-icon');
    var countEl = document.getElementById('like-count');
    button.classList.toggle('liked', isLiked);
    icon.textContent = isLiked ? '\\u2665' : '\\u2661';
    countEl.textContent = count > 0 ? count + ' like' + (count !== 1 ? 's' : '') : '';
  }

  document.addEventListener('DOMContentLoaded', init);
})();
</script>''';
  }

  String _getCommentsScript(String ownerNpub, String filename) {
    final encodedFilename = Uri.encodeComponent(filename);
    return '''
<script>
(function() {
  const ownerNpub = '${escapeHtml(ownerNpub)}';
  const apiBase = '$encodedFilename';
  let userPubkey = null;
  let userNpub = null;
  let userCallsign = null;

  function onConnected(pubkey) {
    userPubkey = pubkey;
    userNpub = window.GeogramNostr ? window.GeogramNostr.npub : null;
    userCallsign = window.GeogramNostr ? (window.GeogramNostr.callsign || window.GeogramNostr.nickname || 'anon') : 'anon';
    var form = document.getElementById('comment-form');
    if (form) form.style.display = 'block';
    // Show delete buttons for own comments and if user is owner
    document.querySelectorAll('.comment').forEach(function(el) {
      var npub = el.getAttribute('data-comment-npub');
      var btn = el.querySelector('.comment-delete');
      if (btn && (npub === userNpub || userNpub === ownerNpub)) {
        btn.style.display = 'inline';
      }
    });
  }

  document.addEventListener('nostr-connected', function(e) { onConnected(e.detail.pubkey); });
  if (window.GeogramNostr && window.GeogramNostr.connected && window.GeogramNostr.pubkey) {
    onConnected(window.GeogramNostr.pubkey);
  }

  window.submitComment = async function() {
    if (!userPubkey || !window.nostr) { alert('Connect with Nostr first'); return; }
    var input = document.getElementById('comment-input');
    var content = input.value.trim();
    if (!content) return;
    var btn = document.getElementById('comment-submit');
    btn.disabled = true;
    try {
      var unsignedEvent = {
        pubkey: userPubkey,
        created_at: Math.floor(Date.now() / 1000),
        kind: 1,
        tags: [['t', 'ndf-comment'], ['callsign', userCallsign]],
        content: content
      };
      var signedEvent = await window.nostr.signEvent(unsignedEvent);
      if (!signedEvent || !signedEvent.sig) throw new Error('Signing failed');
      var resp = await fetch(apiBase + '/comment', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ author: userCallsign, content: content, npub: userNpub, signature: signedEvent.sig })
      });
      var result = await resp.json();
      if (result.success) { input.value = ''; location.reload(); }
    } catch(e) { console.error('Comment error:', e); }
    finally { btn.disabled = false; }
  };

  window.deleteComment = async function(commentId) {
    if (!userNpub) return;
    if (!confirm('Delete this comment?')) return;
    try {
      var resp = await fetch(apiBase + '/comment/' + encodeURIComponent(commentId), {
        method: 'DELETE',
        headers: { 'X-Npub': userNpub }
      });
      var result = await resp.json();
      if (result.success) { location.reload(); }
    } catch(e) { console.error('Delete error:', e); }
  };
})();
</script>''';
  }
}

class _MergeInfo {
  final int colspan;
  final int rowspan;
  final bool skip;

  _MergeInfo({this.colspan = 1, this.rowspan = 1, this.skip = false});

  factory _MergeInfo.covered() =>
      _MergeInfo(skip: true);
}
