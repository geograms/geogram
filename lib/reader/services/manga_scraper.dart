/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';

import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart';
import 'package:http/http.dart' as http;

import '../models/manga_extension.dart';
import '../../services/log_service.dart';

/// Exception thrown when Cloudflare challenge is detected
class CloudflareChallengeException implements Exception {
  final String url;
  CloudflareChallengeException(this.url);
  @override
  String toString() => 'Cloudflare challenge detected at $url';
}

/// Core HTML scraping engine using CSS selectors from extension manifests
class MangaScraper {
  static final MangaScraper _instance = MangaScraper._internal();
  factory MangaScraper() => _instance;
  MangaScraper._internal();

  final _client = http.Client();

  /// Track last request time per extension for rate limiting
  final Map<String, DateTime> _lastRequestTime = {};

  /// Scrape a page using the given config and variable substitutions
  Future<List<Map<String, dynamic>>> scrape({
    required ScrapeConfig config,
    required Map<String, String> vars,
    Map<String, String> headers = const {},
    Map<String, String> cookies = const {},
    String? extensionId,
    int rateLimitMs = 1000,
  }) async {
    // Rate limiting
    await _rateLimit(extensionId ?? '', rateLimitMs);

    final url = _substituteVars(config.url, vars);
    final html = await _fetchHtml(url, headers, cookies);
    final document = html_parser.parse(html);

    if (config.listSelector == null) {
      // Single item (e.g., series info page)
      final result = _extractFields(document.documentElement!, config.fields, vars);
      return [result];
    }

    // Multiple items (e.g., search results, chapter list)
    final items = document.querySelectorAll(config.listSelector!);
    final results = <Map<String, dynamic>>[];

    for (final item in items) {
      final result = _extractFields(item, config.fields, vars);
      if (result.isNotEmpty) {
        results.add(result);
      }
    }

    // Handle ordering
    if (config.order == 'desc') {
      // Chapters listed newest-first on the page; reverse so oldest is first
      return results.reversed.toList();
    }

    return results;
  }

  /// Fetch page image URLs from a chapter
  Future<List<String>> scrapePageUrls({
    required PageConfig config,
    required Map<String, String> vars,
    Map<String, String> headers = const {},
    Map<String, String> cookies = const {},
    String? extensionId,
    int rateLimitMs = 1000,
  }) async {
    await _rateLimit(extensionId ?? '', rateLimitMs);

    final url = _substituteVars(config.url, vars);
    final html = await _fetchHtml(url, headers, cookies);
    final document = html_parser.parse(html);

    final items = document.querySelectorAll(config.listSelector);
    final urls = <String>[];

    for (final item in items) {
      final imgUrl = item.attributes[config.imageAttr];
      if (imgUrl != null && imgUrl.isNotEmpty) {
        urls.add(imgUrl.trim());
      }
    }

    return urls;
  }

  /// Download an image with proper headers
  Future<http.Response> downloadImage(
    String url, {
    Map<String, String> headers = const {},
    Map<String, String> cookies = const {},
    String? extensionId,
    int rateLimitMs = 500,
  }) async {
    await _rateLimit(extensionId ?? '', rateLimitMs);

    final requestHeaders = Map<String, String>.from(headers);
    if (cookies.isNotEmpty) {
      requestHeaders['Cookie'] =
          cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    }

    final response = await _client.get(Uri.parse(url), headers: requestHeaders);
    if (response.statusCode != 200) {
      throw Exception('Failed to download image: ${response.statusCode} $url');
    }
    return response;
  }

  /// Fetch HTML from a URL, detecting Cloudflare challenges
  Future<String> _fetchHtml(
    String url,
    Map<String, String> headers,
    Map<String, String> cookies,
  ) async {
    final requestHeaders = Map<String, String>.from(headers);
    if (cookies.isNotEmpty) {
      requestHeaders['Cookie'] =
          cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    }

    final response =
        await _client.get(Uri.parse(url), headers: requestHeaders);

    if (response.statusCode == 403) {
      final body = response.body.toLowerCase();
      if (body.contains('cf-browser-verification') ||
          body.contains('challenge-platform') ||
          body.contains('cloudflare')) {
        throw CloudflareChallengeException(url);
      }
    }

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode} fetching $url');
    }

    return response.body;
  }

  /// Extract fields from an HTML element using field definitions
  Map<String, dynamic> _extractFields(
    Element element,
    Map<String, ExtensionField> fields,
    Map<String, String> vars,
  ) {
    final result = <String, dynamic>{};

    for (final entry in fields.entries) {
      final fieldName = entry.key;
      final field = entry.value;

      try {
        final value = _extractField(element, field);
        if (value != null) {
          result[fieldName] = value;
        }
      } catch (e) {
        LogService().log('MangaScraper: Error extracting field "$fieldName": $e');
      }
    }

    return result;
  }

  /// Extract a single field value from an element
  dynamic _extractField(Element element, ExtensionField field) {
    if (field.selector == null && field.regex != null) {
      // Regex-only field: apply to the element's text content
      return _applyFieldProcessing(element.text, field);
    }

    if (field.selector == null) {
      // No selector — extract attr/text from the element itself
      if (field.attr != null || field.text) {
        final rawValue = _extractRawValue(element, field);
        if (rawValue == null || rawValue.isEmpty) return null;
        return _applyFieldProcessing(rawValue, field);
      }
      return null;
    }

    if (field.list) {
      // Collect all matching elements
      final elements = element.querySelectorAll(field.selector!);
      return elements
          .map((e) => _extractRawValue(e, field))
          .where((v) => v != null && v.isNotEmpty)
          .map((v) => _applyFieldProcessing(v!, field))
          .toList();
    }

    final target = element.querySelector(field.selector!);
    if (target == null) return null;

    final rawValue = _extractRawValue(target, field);
    if (rawValue == null || rawValue.isEmpty) return null;

    return _applyFieldProcessing(rawValue, field);
  }

  /// Get raw text or attribute from an element
  String? _extractRawValue(Element element, ExtensionField field) {
    if (field.attr != null) {
      return element.attributes[field.attr!]?.trim();
    }
    if (field.text) {
      return element.text.trim();
    }
    return element.text.trim();
  }

  /// Apply regex, type conversion, and mapping to a raw value
  dynamic _applyFieldProcessing(String value, ExtensionField field) {
    // Apply regex
    if (field.regex != null) {
      final match = RegExp(field.regex!).firstMatch(value);
      if (match != null && match.groupCount >= 1) {
        value = match.group(1)!;
      } else {
        return null;
      }
    }

    // Apply mapping
    if (field.map != null && field.map!.containsKey(value)) {
      value = field.map![value]!;
    }

    // Type conversion
    if (field.type == 'number') {
      return double.tryParse(value);
    }

    return value;
  }

  /// Substitute template variables in a URL
  String _substituteVars(String template, Map<String, String> vars) {
    var result = template;
    for (final entry in vars.entries) {
      result = result.replaceAll('{${entry.key}}', entry.value);
    }
    return result;
  }

  /// Apply rate limiting between requests
  Future<void> _rateLimit(String extensionId, int rateLimitMs) async {
    final key = extensionId.isEmpty ? '_global' : extensionId;
    final last = _lastRequestTime[key];
    if (last != null) {
      final elapsed = DateTime.now().difference(last).inMilliseconds;
      if (elapsed < rateLimitMs) {
        await Future.delayed(Duration(milliseconds: rateLimitMs - elapsed));
      }
    }
    _lastRequestTime[key] = DateTime.now();
  }

  /// Substitute variables in headers
  Map<String, String> resolveHeaders(
      Map<String, String> headers, Map<String, String> vars) {
    return headers.map(
      (k, v) => MapEntry(k, _substituteVars(v, vars)),
    );
  }

  void dispose() {
    _client.close();
  }
}
