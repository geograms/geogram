import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';

import '../models/place.dart';

/// Pure Dart parser for place.txt content (no Flutter dependencies).
class PlaceParser {
  PlaceParser._();

  /// Parse place.txt content into a Place model.
  /// Returns null if required fields are missing or invalid.
  static Place? parsePlaceContent({
    required String content,
    required String filePath,
    required String folderPath,
    String regionName = '',
    void Function(String message)? log,
  }) {
    final lines = content.split('\n');

    // Parse header
    String? name;
    final names = <String, String>{};
    String? created;
    String? author;
    double? latitude;
    double? longitude;
    int? radius;
    String? address;
    String? type;
    String? founded;
    String? hours;
    final admins = <String>[];
    final moderators = <String>[];
    String? metadataNpub;
    String? signature;

    // Parse description/history
    String description = '';
    final descriptions = <String, String>{};
    String? history;
    final histories = <String, String>{};

    bool inHeader = true;
    String? currentLang;
    final descriptionBuffer = StringBuffer();
    final historyBuffer = StringBuffer();
    bool inHistory = false;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();

      // Parse title line
      if (trimmed.startsWith('# PLACE:')) {
        name = trimmed.substring(8).trim();
      } else if (trimmed.startsWith('# PLACE_')) {
        final parts = trimmed.substring(2).split(':');
        if (parts.length == 2) {
          final langCode = parts[0].substring(6).trim(); // Extract language code
          names[langCode] = parts[1].trim();
          if (name == null) name = parts[1].trim();
        }
      }
      // Parse metadata fields
      else if (trimmed.startsWith('CREATED:')) {
        created = trimmed.substring(8).trim();
      } else if (trimmed.startsWith('AUTHOR:')) {
        author = trimmed.substring(7).trim();
      } else if (trimmed.startsWith('COORDINATES:')) {
        final coords = trimmed.substring(12).trim().split(',');
        if (coords.length == 2) {
          latitude = double.tryParse(coords[0].trim());
          longitude = double.tryParse(coords[1].trim());
        }
      } else if (trimmed.startsWith('RADIUS:')) {
        radius = int.tryParse(trimmed.substring(7).trim());
      } else if (trimmed.startsWith('ADDRESS:')) {
        address = trimmed.substring(8).trim();
      } else if (trimmed.startsWith('TYPE:')) {
        type = trimmed.substring(5).trim();
      } else if (trimmed.startsWith('FOUNDED:')) {
        founded = trimmed.substring(8).trim();
      } else if (trimmed.startsWith('HOURS:')) {
        hours = trimmed.substring(6).trim();
      } else if (trimmed.startsWith('ADMINS:')) {
        final adminList = trimmed.substring(7).trim().split(',');
        admins.addAll(adminList.map((a) => a.trim()).where((a) => a.isNotEmpty));
      } else if (trimmed.startsWith('MODERATORS:')) {
        final modList = trimmed.substring(11).trim().split(',');
        moderators.addAll(modList.map((m) => m.trim()).where((m) => m.isNotEmpty));
      }
      // Parse NOSTR metadata
      else if (trimmed.startsWith('--> npub:')) {
        metadataNpub = trimmed.substring(9).trim();
      } else if (trimmed.startsWith('--> signature:')) {
        signature = trimmed.substring(14).trim();
      }
      // Language sections
      else if (RegExp(r'^\[([A-Z]{2})\]$').hasMatch(trimmed)) {
        inHeader = false;
        currentLang = RegExp(r'^\[([A-Z]{2})\]$').firstMatch(trimmed)!.group(1);
        descriptionBuffer.clear();
      }
      // History sections
      else if (trimmed.startsWith('HISTORY:')) {
        inHeader = false;
        inHistory = true;
        historyBuffer.clear();
        final histText = trimmed.substring(8).trim();
        if (histText.isNotEmpty) {
          historyBuffer.writeln(histText);
        }
      } else if (RegExp(r'^HISTORY_([A-Z]{2}):').hasMatch(trimmed)) {
        inHeader = false;
        inHistory = true;
        final match = RegExp(r'^HISTORY_([A-Z]{2}):').firstMatch(trimmed);
        currentLang = match!.group(1);
        historyBuffer.clear();
        final histText = trimmed.substring(match.group(0)!.length).trim();
        if (histText.isNotEmpty) {
          historyBuffer.writeln(histText);
        }
      }
      // Content lines
      else if (!inHeader && trimmed.isNotEmpty && !trimmed.startsWith('-->')) {
        if (inHistory) {
          historyBuffer.writeln(line);
        } else {
          descriptionBuffer.writeln(line);
        }
      }
      // Empty line - save current section
      else if (trimmed.isEmpty && !inHeader) {
        if (currentLang != null) {
          if (inHistory) {
            if (historyBuffer.isNotEmpty) {
              histories[currentLang] = historyBuffer.toString().trim();
              historyBuffer.clear();
            }
          } else {
            if (descriptionBuffer.isNotEmpty) {
              descriptions[currentLang] = descriptionBuffer.toString().trim();
              descriptionBuffer.clear();
            }
          }
        } else if (inHistory) {
          history = historyBuffer.toString().trim();
          historyBuffer.clear();
        } else {
          description = descriptionBuffer.toString().trim();
          descriptionBuffer.clear();
        }
      }
      // Check if we've left the header
      else if (inHeader && trimmed.isEmpty && created != null) {
        inHeader = false;
      }
    }

    // Save any remaining content
    if (currentLang != null) {
      if (inHistory && historyBuffer.isNotEmpty) {
        histories[currentLang] = historyBuffer.toString().trim();
      } else if (descriptionBuffer.isNotEmpty) {
        descriptions[currentLang] = descriptionBuffer.toString().trim();
      }
    } else if (inHistory && historyBuffer.isNotEmpty) {
      history = historyBuffer.toString().trim();
    } else if (descriptionBuffer.isNotEmpty) {
      description = descriptionBuffer.toString().trim();
    }

    // Validate required fields
    if (name == null || created == null || author == null ||
        latitude == null || longitude == null || radius == null) {
      log?.call('Missing required fields in $filePath');
      return null;
    }

    // Count photos (files in folder and images/ subfolder)
    var photoCount = 0;
    try {
      final folder = Directory(folderPath);
      final entities = folder.listSync();
      photoCount = entities.where((e) {
        if (e is! File) return false;
        final name = e.path.split('/').last;
        return name != 'place.txt' &&
               (name.endsWith('.jpg') || name.endsWith('.jpeg') ||
                name.endsWith('.png') || name.endsWith('.gif'));
      }).length;
      final imagesDir = Directory('$folderPath/images');
      if (imagesDir.existsSync()) {
        final imageEntities = imagesDir.listSync();
        photoCount += imageEntities.where((e) {
          if (e is! File) return false;
          final name = e.path.split('/').last;
          return name.endsWith('.jpg') || name.endsWith('.jpeg') ||
              name.endsWith('.png') || name.endsWith('.gif') ||
              name.endsWith('.webp');
        }).length;
      }
    } catch (e) {
      // Ignore errors
    }

    return Place(
      name: name,
      names: names,
      created: created,
      author: author,
      latitude: latitude,
      longitude: longitude,
      radius: radius,
      address: address,
      type: type,
      founded: founded,
      hours: hours,
      description: description,
      descriptions: descriptions,
      history: history,
      histories: histories,
      admins: admins,
      moderators: moderators,
      metadataNpub: metadataNpub,
      signature: signature,
      filePath: filePath,
      folderPath: folderPath,
      regionPath: regionName,
      photoCount: photoCount,
    );
  }
}
