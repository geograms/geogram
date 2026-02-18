#!/usr/bin/env dart
/// Script to generate themes_embedded.dart from the themes folder
/// Run this script whenever you modify theme files:
///   dart bin/generate_embedded_themes.dart
///
/// This will update lib/cli/themes_embedded.dart with all theme files
/// (HTML templates and CSS) from the themes/default folder.

import 'dart:io';

Future<void> main() async {
  final themesDir = Directory('themes/default');
  final outputFile = File('lib/cli/themes_embedded.dart');

  if (!await themesDir.exists()) {
    print('Error: themes/default folder not found');
    exit(1);
  }

  // Collect all .html and .css files recursively
  final themeFiles = <File>[];
  await for (final entity in themesDir.list(recursive: true)) {
    if (entity is File &&
        (entity.path.endsWith('.html') || entity.path.endsWith('.css'))) {
      themeFiles.add(entity);
    }
  }

  themeFiles.sort((a, b) => a.path.compareTo(b.path));

  if (themeFiles.isEmpty) {
    print('Error: No theme files found in themes/default');
    exit(1);
  }

  print('Found ${themeFiles.length} theme files:');
  for (final file in themeFiles) {
    print('  - ${file.path}');
  }

  // Generate the Dart file
  final buffer = StringBuffer();

  buffer.writeln('/// Embedded theme files for CLI distribution');
  buffer.writeln(
      '/// These themes are bundled with the CLI binary and extracted on startup');
  buffer.writeln('///');
  buffer.writeln('/// AUTO-GENERATED FILE - DO NOT EDIT MANUALLY');
  buffer.writeln('/// Run: dart bin/generate_embedded_themes.dart');
  buffer.writeln('');
  buffer.writeln('class ThemesEmbedded {');
  buffer.writeln(
      '  /// Map of relative path (under themes/) to file content');
  buffer.writeln('  static const Map<String, String> files = {');

  // Add each file to the map
  for (var i = 0; i < themeFiles.length; i++) {
    final file = themeFiles[i];
    // Path relative to themes/ directory, e.g. "default/styles.css"
    final relativePath =
        file.path.replaceFirst('themes/', '');
    final varName = _toVariableName(relativePath);
    final trailing = i < themeFiles.length - 1 ? ',' : '';
    buffer.writeln("    '$relativePath': _$varName$trailing");
  }

  buffer.writeln('  };');
  buffer.writeln('');

  // Add each file's content as a constant
  for (final file in themeFiles) {
    final relativePath =
        file.path.replaceFirst('themes/', '');
    final varName = _toVariableName(relativePath);
    final content = await file.readAsString();

    buffer.writeln("  static const String _$varName = r'''");
    buffer.write(content);
    if (!content.endsWith('\n')) {
      buffer.writeln();
    }
    buffer.writeln("''';");
    buffer.writeln('');
  }

  buffer.writeln('}');

  // Write the output file
  await outputFile.writeAsString(buffer.toString());

  print('');
  print('Generated: ${outputFile.path}');
  print('Done!');
}

/// Convert a relative path to a valid Dart variable name
String _toVariableName(String path) {
  // e.g. "default/chat/index.html" -> "defaultChatIndexHtml"
  final parts = path.split(RegExp(r'[/\-_.]'));

  if (parts.isEmpty) return path;

  final result = StringBuffer(parts[0].toLowerCase());
  for (var i = 1; i < parts.length; i++) {
    final part = parts[i];
    if (part.isNotEmpty) {
      result.write(part[0].toUpperCase());
      if (part.length > 1) {
        result.write(part.substring(1).toLowerCase());
      }
    }
  }

  return result.toString();
}
