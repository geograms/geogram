// Tool to split monolithic language files into per-feature files
// Run with: dart tools/split_languages.dart

import 'dart:convert';
import 'dart:io';

/// Maps feature names to their key prefixes
const Map<String, List<String>> featurePrefixes = {
  'bot': ['bot_'],
  'backup': ['backup_'],
  'transfer': ['transfer_'],
  'collection': ['collection_'],
  'places': ['place_', 'place_type_', 'location_'],
  'groups': ['group_', 'group_type_', 'member_'],
  'event': ['event_'],
  'station': ['station_'],
  'chat': ['chat_', 'channel_', 'dm_'],
  'onboarding': ['onboarding_'],
  'settings': ['profile_', 'update_', 'nostr_', 'notification_'],
};

void main() async {
  final languages = ['en_US', 'pt_PT'];

  for (final lang in languages) {
    await splitLanguageFile(lang);
  }

  print('\nDone! Language files have been split.');
  print('Next steps:');
  print('1. Update lib/services/i18n_service.dart');
  print('2. Update pubspec.yaml assets');
  print('3. Test the app');
}

Future<void> splitLanguageFile(String language) async {
  print('\n=== Processing $language ===');

  // Read the monolithic file
  final inputFile = File('languages/$language.json');
  if (!inputFile.existsSync()) {
    print('ERROR: File not found: languages/$language.json');
    return;
  }

  final jsonString = await inputFile.readAsString();
  final Map<String, dynamic> allKeys = json.decode(jsonString);
  print('Total keys in source: ${allKeys.length}');

  // Create output directory
  final outputDir = Directory('languages/$language');
  if (!outputDir.existsSync()) {
    outputDir.createSync(recursive: true);
  }

  // Categorize keys
  final Map<String, Map<String, String>> featureKeys = {};

  // Initialize all features including common
  for (final feature in featurePrefixes.keys) {
    featureKeys[feature] = {};
  }
  featureKeys['common'] = {};

  // Sort keys into features
  for (final entry in allKeys.entries) {
    final key = entry.key;
    final value = entry.value.toString();

    String targetFeature = 'common';

    // Check each feature's prefixes
    for (final featureEntry in featurePrefixes.entries) {
      for (final prefix in featureEntry.value) {
        if (key.startsWith(prefix)) {
          targetFeature = featureEntry.key;
          break;
        }
      }
      if (targetFeature != 'common') break;
    }

    featureKeys[targetFeature]![key] = value;
  }

  // Write feature files
  int totalWritten = 0;
  for (final entry in featureKeys.entries) {
    final feature = entry.key;
    final keys = entry.value;

    if (keys.isEmpty) {
      print('  $feature: 0 keys (skipped)');
      continue;
    }

    // Sort keys alphabetically for consistent output
    final sortedKeys = Map.fromEntries(
      keys.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );

    final outputFile = File('languages/$language/$feature.json');
    final encoder = JsonEncoder.withIndent('  ');
    await outputFile.writeAsString(encoder.convert(sortedKeys));

    print('  $feature: ${keys.length} keys');
    totalWritten += keys.length;
  }

  print('Total keys written: $totalWritten');

  // Validate
  if (totalWritten == allKeys.length) {
    print('Validation PASSED: All keys accounted for');
  } else {
    print('Validation FAILED: Expected ${allKeys.length}, got $totalWritten');
  }

  // Backup original file
  final backupFile = File('languages/$language.json.backup');
  if (!backupFile.existsSync()) {
    await inputFile.copy('languages/$language.json.backup');
    print('Original file backed up to: languages/$language.json.backup');
  }
}
