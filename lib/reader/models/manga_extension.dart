/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Model for a manga extension (JSON manifest with CSS selectors)
class MangaExtension {
  final String id;
  final String name;
  final String version;
  final int apiVersion;
  final String language;
  final String baseUrl;
  final int rateLimitMs;
  final bool needsWebview;
  final Map<String, String> headers;
  final ScrapeConfig search;
  final ScrapeConfig series;
  final ScrapeConfig chapters;
  final PageConfig pages;
  final List<BrowseConfig> browse;

  MangaExtension({
    required this.id,
    required this.name,
    required this.version,
    this.apiVersion = 1,
    this.language = 'en',
    required this.baseUrl,
    this.rateLimitMs = 1000,
    this.needsWebview = false,
    this.headers = const {},
    required this.search,
    required this.series,
    required this.chapters,
    required this.pages,
    this.browse = const [],
  });

  factory MangaExtension.fromJson(Map<String, dynamic> json) {
    return MangaExtension(
      id: json['id'] as String,
      name: json['name'] as String,
      version: json['version'] as String? ?? '1.0.0',
      apiVersion: json['api_version'] as int? ?? 1,
      language: json['language'] as String? ?? 'en',
      baseUrl: json['base_url'] as String,
      rateLimitMs: json['rate_limit_ms'] as int? ?? 1000,
      needsWebview: json['needs_webview'] as bool? ?? false,
      headers: (json['headers'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as String)) ??
          {},
      search: ScrapeConfig.fromJson(json['search'] as Map<String, dynamic>),
      series: ScrapeConfig.fromJson(json['series'] as Map<String, dynamic>),
      chapters:
          ScrapeConfig.fromJson(json['chapters'] as Map<String, dynamic>),
      pages: PageConfig.fromJson(json['pages'] as Map<String, dynamic>),
      browse: (json['browse'] as List<dynamic>?)
              ?.map((b) =>
                  BrowseConfig.fromJson(b as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        'api_version': apiVersion,
        'language': language,
        'base_url': baseUrl,
        'rate_limit_ms': rateLimitMs,
        'needs_webview': needsWebview,
        'headers': headers,
        'search': search.toJson(),
        'series': series.toJson(),
        'chapters': chapters.toJson(),
        'pages': pages.toJson(),
        if (browse.isNotEmpty)
          'browse': browse.map((b) => b.toJson()).toList(),
      };
}

/// A browseable catalog page (popular, latest, etc.)
class BrowseConfig {
  final String name;
  final ScrapeConfig config;

  BrowseConfig({required this.name, required this.config});

  factory BrowseConfig.fromJson(Map<String, dynamic> json) {
    return BrowseConfig(
      name: json['name'] as String,
      config: ScrapeConfig.fromJson(json),
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        ...config.toJson(),
      };
}

/// Configuration for scraping a page section (search, series info, chapters)
class ScrapeConfig {
  final String url;
  final String? listSelector;
  final String? order;
  final Map<String, ExtensionField> fields;
  final ExtensionField? nextPage;

  ScrapeConfig({
    required this.url,
    this.listSelector,
    this.order,
    this.fields = const {},
    this.nextPage,
  });

  factory ScrapeConfig.fromJson(Map<String, dynamic> json) {
    final fieldsJson = json['fields'] as Map<String, dynamic>? ?? {};
    return ScrapeConfig(
      url: json['url'] as String,
      listSelector: json['list_selector'] as String?,
      order: json['order'] as String?,
      fields: fieldsJson.map(
        (k, v) => MapEntry(k, ExtensionField.fromJson(v as Map<String, dynamic>)),
      ),
      nextPage: json['next_page'] != null
          ? ExtensionField.fromJson(json['next_page'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        if (listSelector != null) 'list_selector': listSelector,
        if (order != null) 'order': order,
        'fields': fields.map((k, v) => MapEntry(k, v.toJson())),
        if (nextPage != null) 'next_page': nextPage!.toJson(),
      };
}

/// A field extraction rule: CSS selector + text/attr/regex/map
class ExtensionField {
  final String? selector;
  final String? attr;
  final String? regex;
  final String? type;
  final bool text;
  final bool list;
  final Map<String, String>? map;

  ExtensionField({
    this.selector,
    this.attr,
    this.regex,
    this.type,
    this.text = false,
    this.list = false,
    this.map,
  });

  factory ExtensionField.fromJson(Map<String, dynamic> json) {
    return ExtensionField(
      selector: json['selector'] as String?,
      attr: json['attr'] as String?,
      regex: json['regex'] as String?,
      type: json['type'] as String?,
      text: json['text'] as bool? ?? false,
      list: json['list'] as bool? ?? false,
      map: (json['map'] as Map<String, dynamic>?)
          ?.map((k, v) => MapEntry(k, v as String)),
    );
  }

  Map<String, dynamic> toJson() => {
        if (selector != null) 'selector': selector,
        if (attr != null) 'attr': attr,
        if (regex != null) 'regex': regex,
        if (type != null) 'type': type,
        if (text) 'text': text,
        if (list) 'list': list,
        if (map != null) 'map': map,
      };
}

/// Configuration for extracting page image URLs from a chapter page
class PageConfig {
  final String url;
  final String listSelector;
  final String imageAttr;
  final String? referer;

  PageConfig({
    required this.url,
    required this.listSelector,
    required this.imageAttr,
    this.referer,
  });

  factory PageConfig.fromJson(Map<String, dynamic> json) {
    return PageConfig(
      url: json['url'] as String,
      listSelector: json['list_selector'] as String,
      imageAttr: json['image_attr'] as String,
      referer: json['referer'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'list_selector': listSelector,
        'image_attr': imageAttr,
        if (referer != null) 'referer': referer,
      };
}
