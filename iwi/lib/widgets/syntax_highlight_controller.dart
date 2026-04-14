/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Ported from the parent repo's lib/widgets/syntax_highlight_controller.dart
 * with only the import paths adjusted. The highlighting and
 * flutter_highlighting packages must be declared in iwi/pubspec.yaml.
 */

import 'package:flutter/material.dart';
import 'package:highlighting/highlighting.dart';
import 'package:flutter_highlighting/themes/vs2015.dart';
import 'package:flutter_highlighting/themes/github.dart';

/// Maps file extensions to highlight.js language IDs.
///
/// Reusable: import this map anywhere you need extension → language mapping.
const extensionToLanguageId = <String, String>{
  // Data / config
  'json': 'json',
  'xml': 'xml',
  'yaml': 'yaml',
  'yml': 'yaml',
  'toml': 'ini', // highlight.js ini covers TOML well enough
  'ini': 'ini',
  'conf': 'ini',
  'cfg': 'ini',
  'properties': 'properties',

  // Markup / style
  'html': 'xml',
  'htm': 'xml',
  'css': 'css',
  'scss': 'scss',
  'sass': 'css',
  'less': 'less',

  // JavaScript family
  'js': 'javascript',
  'jsx': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'vue': 'xml',
  'svelte': 'xml',

  // Dart
  'dart': 'dart',

  // Python
  'py': 'python',

  // JVM
  'java': 'java',
  'kt': 'kotlin',
  'scala': 'scala',
  'gradle': 'gradle',

  // C family
  'c': 'c',
  'cpp': 'cpp',
  'h': 'c',

  // Shell
  'sh': 'bash',
  'bash': 'bash',
  'zsh': 'bash',
  'fish': 'bash',
  'bat': 'dos',
  'ps1': 'powershell',

  // Go / Rust / Ruby / PHP
  'go': 'go',
  'rs': 'rust',
  'rb': 'ruby',
  'php': 'php',

  // SQL
  'sql': 'sql',

  // Lua
  'lua': 'lua',

  // Swift
  'swift': 'swift',

  // R
  'r': 'r',

  // Perl
  'pl': 'perl',
  'pm': 'perl',

  // Haskell
  'hs': 'haskell',

  // Elixir
  'ex': 'elixir',
  'exs': 'elixir',

  // Clojure
  'clj': 'clojure',

  // Zig / Nim
  'zig': 'plaintext', // no highlight.js grammar yet
  'nim': 'nim',

  // Build / infra
  'makefile': 'makefile',
  'dockerfile': 'dockerfile',
  'tf': 'plaintext', // Terraform/HCL

  // GraphQL
  'graphql': 'graphql',
  'gql': 'graphql',

  // Markdown (handled separately by the viewer, but included for completeness)
  'md': 'markdown',
  'markdown': 'markdown',
};

/// Plain-text extensions that should NOT get syntax coloring.
const _plainTextExtensions = {
  'txt', 'log', 'csv',
};

/// Returns the highlight.js language ID for a file path, or null if the
/// file should be rendered as plain text.
String? languageIdForFile(String filePath) {
  final base = filePath.split('/').last.toLowerCase();

  // Handle extensionless filenames like Makefile, Dockerfile
  if (base == 'makefile' || base == 'gnumakefile') return 'makefile';
  if (base == 'dockerfile') return 'dockerfile';

  final dot = base.lastIndexOf('.');
  if (dot == -1) return null;

  final ext = base.substring(dot + 1);
  if (_plainTextExtensions.contains(ext)) return null;
  return extensionToLanguageId[ext];
}

/// Maximum file size (in bytes) that will be syntax-highlighted.
/// Files above this fall back to plain text for performance.
const _maxHighlightSize = 100 * 1024; // 100 KB

/// Converts a highlight.js node tree into a list of [TextSpan].
///
/// Reusable: call this from any widget that needs to render highlighted code
/// without using [SyntaxHighlightController] (e.g. read-only preview).
List<TextSpan> convertNodesToSpans(
  List<Node> nodes,
  Map<String, TextStyle> theme,
) {
  final spans = <TextSpan>[];
  var currentSpans = spans;
  final stack = <List<TextSpan>>[];

  void traverse(Node node) {
    if (node.value != null) {
      currentSpans.add(node.className == null
          ? TextSpan(text: node.value)
          : TextSpan(text: node.value, style: theme[node.className]));
    } else {
      final tmp = <TextSpan>[];
      currentSpans.add(TextSpan(children: tmp, style: theme[node.className]));
      stack.add(currentSpans);
      currentSpans = tmp;

      for (final n in node.children) {
        traverse(n);
        if (identical(n, node.children.last)) {
          currentSpans = stack.isEmpty ? spans : stack.removeLast();
        }
      }
    }
  }

  for (final node in nodes) {
    traverse(node);
  }
  return spans;
}

/// A [TextEditingController] that applies syntax highlighting to its text.
///
/// Reusable: drop this into any [TextField] for live syntax coloring.
class SyntaxHighlightController extends TextEditingController {
  SyntaxHighlightController({
    required String languageId,
    Brightness brightness = Brightness.dark,
    super.text,
  })  : _languageId = languageId,
        _theme = brightness == Brightness.dark ? vs2015Theme : githubTheme;

  final String _languageId;
  Map<String, TextStyle> _theme;

  // Cache: avoid re-parsing on every frame if text hasn't changed.
  String? _cachedText;
  List<TextSpan>? _cachedSpans;

  /// Call this when the app brightness changes so colors stay correct.
  void updateBrightness(Brightness brightness) {
    final newTheme =
        brightness == Brightness.dark ? vs2015Theme : githubTheme;
    if (!identical(newTheme, _theme)) {
      _theme = newTheme;
      _cachedText = null; // force re-render
      notifyListeners();
    }
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final currentText = text;

    // Skip highlighting for oversized files
    if (currentText.length > _maxHighlightSize) {
      return TextSpan(text: currentText, style: style);
    }

    // Return cached result if text unchanged
    if (currentText == _cachedText && _cachedSpans != null) {
      return TextSpan(style: style, children: _cachedSpans);
    }

    try {
      final result = highlight.parse(currentText, languageId: _languageId);
      final nodes = result.nodes;
      if (nodes == null || nodes.isEmpty) {
        return TextSpan(text: currentText, style: style);
      }
      _cachedSpans = convertNodesToSpans(nodes, _theme);
      _cachedText = currentText;
      return TextSpan(style: style, children: _cachedSpans);
    } catch (_) {
      // If parsing fails, fall back to plain text
      return TextSpan(text: currentText, style: style);
    }
  }
}
