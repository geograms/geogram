/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import '../models/contact.dart';

/// Service for managing contacts collection (people and machines)
class ContactService {
  static final ContactService _instance = ContactService._internal();
  factory ContactService() => _instance;
  ContactService._internal();

  String? _collectionPath;

  /// Initialize contact service for a collection
  Future<void> initializeCollection(String collectionPath) async {
    print('ContactService: Initializing with collection path: $collectionPath');
    _collectionPath = collectionPath;

    // Ensure contacts directory exists
    final contactsDir = Directory('$collectionPath/contacts');
    if (!await contactsDir.exists()) {
      await contactsDir.create(recursive: true);
      print('ContactService: Created contacts directory');
    }

    // Ensure profile-pictures directory exists
    final profilePicturesDir = Directory('$collectionPath/contacts/profile-pictures');
    if (!await profilePicturesDir.exists()) {
      await profilePicturesDir.create(recursive: true);
      print('ContactService: Created profile-pictures directory');
    }
  }

  /// Load all contacts (with optional group filter)
  Future<List<Contact>> loadContacts({String? groupPath}) async {
    if (_collectionPath == null) return [];

    final contacts = <Contact>[];
    final searchPath = groupPath != null && groupPath.isNotEmpty
        ? '$_collectionPath/contacts/$groupPath'
        : '$_collectionPath/contacts';

    final searchDir = Directory(searchPath);
    if (!await searchDir.exists()) return [];

    final entities = await searchDir.list().toList();


    for (var entity in entities) {
      if (entity is File && entity.path.endsWith('.txt')) {
        // Skip group.txt and hidden files
        final filename = entity.path.split('/').last;
        if (filename == 'group.txt' || filename.startsWith('.')) continue;

        try {
          final contact = await loadContactFromFile(entity.path);
          if (contact != null) {
            contacts.add(contact);
          }
        } catch (e) {
          print('ContactService: Error loading contact ${entity.path}: $e');
        }
      }
    }

    // Sort by display name
    contacts.sort((a, b) => a.displayName.compareTo(b.displayName));

    return contacts;
  }

  /// Load all contacts recursively (including subgroups)
  Future<List<Contact>> loadAllContactsRecursively() async {
    if (_collectionPath == null) return [];

    final contacts = <Contact>[];
    final contactsDir = Directory('$_collectionPath/contacts');
    if (!await contactsDir.exists()) return [];

    await _loadContactsRecursive(contactsDir, '', contacts);

    // Sort by display name
    contacts.sort((a, b) => a.displayName.compareTo(b.displayName));

    return contacts;
  }

  /// Recursively load contacts from directory
  Future<void> _loadContactsRecursive(
    Directory dir,
    String relativePath,
    List<Contact> contacts,
  ) async {
    final entities = await dir.list().toList();

    for (var entity in entities) {
      if (entity is File && entity.path.endsWith('.txt')) {
        // Skip group.txt, hidden files, and profile-pictures
        final filename = entity.path.split('/').last;
        if (filename == 'group.txt' || filename.startsWith('.')) continue;
        if (entity.path.contains('/profile-pictures/')) continue;

        try {
          final contact = await loadContactFromFile(entity.path);
          if (contact != null) {
            contacts.add(contact);
          }
        } catch (e) {
          print('ContactService: Error loading contact ${entity.path}: $e');
        }
      } else if (entity is Directory) {
        // Skip profile-pictures and hidden directories
        final dirname = entity.path.split('/').last;
        if (dirname == 'profile-pictures' || dirname.startsWith('.')) continue;

        final newRelativePath = relativePath.isEmpty
            ? dirname
            : '$relativePath/$dirname';
        await _loadContactsRecursive(entity, newRelativePath, contacts);
      }
    }
  }

  /// Load single contact from file path
  Future<Contact?> loadContactFromFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return null;

    try {
      final content = await file.readAsString();
      final contact = await parseContactFile(content, filePath);
      return contact;
    } catch (e) {
      print('ContactService: Error reading contact file $filePath: $e');
      return null;
    }
  }

  /// Load single contact by callsign
  Future<Contact?> loadContact(String callsign, {String? groupPath}) async {
    if (_collectionPath == null) return null;

    final searchPath = groupPath != null && groupPath.isNotEmpty
        ? '$_collectionPath/contacts/$groupPath'
        : '$_collectionPath/contacts';

    final file = File('$searchPath/$callsign.txt');
    if (!await file.exists()) return null;

    return await loadContactFromFile(file.path);
  }

  /// Parse contact file content
  Future<Contact?> parseContactFile(String content, String filePath) async {
    final lines = content.split('\n');
    if (lines.isEmpty) return null;

    String? displayName;
    String? callsign;
    String? npub;
    String? created;
    String? firstSeen;

    final emails = <String>[];
    final phones = <String>[];
    final addresses = <String>[];
    final websites = <String>[];
    final locations = <ContactLocation>[];
    String? profilePicture;

    bool revoked = false;
    String? revocationReason;
    String? successor;
    String? successorSince;
    String? previousIdentity;
    String? previousIdentitySince;

    final notesLines = <String>[];
    String? metadataNpub;
    String? signature;

    bool inNotes = false;
    bool inMetadata = false;

    for (var line in lines) {
      final trimmed = line.trim();

      // Parse header
      if (trimmed.startsWith('# CONTACT:')) {
        displayName = trimmed.substring('# CONTACT:'.length).trim();
        continue;
      }

      // Parse metadata section
      if (trimmed.startsWith('--> npub:')) {
        inNotes = false;
        inMetadata = true;
        metadataNpub = trimmed.substring('--> npub:'.length).trim();
        continue;
      }

      if (trimmed.startsWith('--> signature:')) {
        signature = trimmed.substring('--> signature:'.length).trim();
        continue;
      }

      // Skip empty lines unless in notes
      if (trimmed.isEmpty) {
        if (inNotes) {
          notesLines.add('');
        }
        continue;
      }

      // Parse fields
      if (trimmed.startsWith('CALLSIGN:')) {
        callsign = trimmed.substring('CALLSIGN:'.length).trim();
      } else if (trimmed.startsWith('NPUB:')) {
        npub = trimmed.substring('NPUB:'.length).trim();
      } else if (trimmed.startsWith('CREATED:')) {
        created = trimmed.substring('CREATED:'.length).trim();
      } else if (trimmed.startsWith('FIRST_SEEN:')) {
        firstSeen = trimmed.substring('FIRST_SEEN:'.length).trim();
      } else if (trimmed.startsWith('EMAIL:')) {
        emails.add(trimmed.substring('EMAIL:'.length).trim());
      } else if (trimmed.startsWith('PHONE:')) {
        phones.add(trimmed.substring('PHONE:'.length).trim());
      } else if (trimmed.startsWith('ADDRESS:')) {
        addresses.add(trimmed.substring('ADDRESS:'.length).trim());
      } else if (trimmed.startsWith('WEBSITE:')) {
        websites.add(trimmed.substring('WEBSITE:'.length).trim());
      } else if (trimmed.startsWith('LOCATIONS:')) {
        final locationsStr = trimmed.substring('LOCATIONS:'.length).trim();
        locations.addAll(_parseLocations(locationsStr));
      } else if (trimmed.startsWith('PROFILE_PICTURE:')) {
        profilePicture = trimmed.substring('PROFILE_PICTURE:'.length).trim();
      } else if (trimmed.startsWith('REVOKED:')) {
        final value = trimmed.substring('REVOKED:'.length).trim().toLowerCase();
        revoked = value == 'true';
      } else if (trimmed.startsWith('REVOCATION_REASON:')) {
        revocationReason = trimmed.substring('REVOCATION_REASON:'.length).trim();
      } else if (trimmed.startsWith('SUCCESSOR:')) {
        successor = trimmed.substring('SUCCESSOR:'.length).trim();
      } else if (trimmed.startsWith('SUCCESSOR_SINCE:')) {
        successorSince = trimmed.substring('SUCCESSOR_SINCE:'.length).trim();
      } else if (trimmed.startsWith('PREVIOUS_IDENTITY:')) {
        previousIdentity = trimmed.substring('PREVIOUS_IDENTITY:'.length).trim();
      } else if (trimmed.startsWith('PREVIOUS_IDENTITY_SINCE:')) {
        previousIdentitySince = trimmed.substring('PREVIOUS_IDENTITY_SINCE:'.length).trim();
      } else if (!inMetadata && !trimmed.startsWith('#')) {
        // This is notes content
        inNotes = true;
        notesLines.add(line); // Preserve original formatting
      }
    }

    // Validate required fields
    if (displayName == null || callsign == null || npub == null || created == null || firstSeen == null) {
      print('ContactService: Missing required fields in contact file');
      return null;
    }

    // Determine group path from file path
    String? groupPath;
    if (filePath.contains('/contacts/')) {
      final pathParts = filePath.split('/contacts/');
      if (pathParts.length > 1) {
        final afterContacts = pathParts[1];
        final parts = afterContacts.split('/');
        if (parts.length > 1) {
          // Remove filename and join remaining parts
          parts.removeLast();
          groupPath = parts.join('/');
        }
      }
    }

    return Contact(
      displayName: displayName,
      callsign: callsign,
      npub: npub,
      created: created,
      firstSeen: firstSeen,
      emails: emails,
      phones: phones,
      addresses: addresses,
      websites: websites,
      locations: locations,
      profilePicture: profilePicture,
      revoked: revoked,
      revocationReason: revocationReason,
      successor: successor,
      successorSince: successorSince,
      previousIdentity: previousIdentity,
      previousIdentitySince: previousIdentitySince,
      notes: notesLines.join('\n').trim(),
      metadataNpub: metadataNpub,
      signature: signature,
      filePath: filePath,
      groupPath: groupPath ?? '',
    );
  }

  /// Parse locations string (format: "Name (lat,lon), Name2, Name3 (lat,lon)")
  List<ContactLocation> _parseLocations(String locationsStr) {
    final locations = <ContactLocation>[];
    final parts = locationsStr.split(',');

    for (var part in parts) {
      part = part.trim();
      if (part.isEmpty) continue;

      // Check if it has coordinates: Name (lat,lon)
      final coordsMatch = RegExp(r'(.+?)\s*\((-?\d+\.?\d*),(-?\d+\.?\d*)\)').firstMatch(part);
      if (coordsMatch != null) {
        final name = coordsMatch.group(1)!.trim();
        final lat = double.tryParse(coordsMatch.group(2)!);
        final lon = double.tryParse(coordsMatch.group(3)!);
        if (lat != null && lon != null) {
          locations.add(ContactLocation(name: name, latitude: lat, longitude: lon));
        }
      } else {
        // Just a name without coordinates
        locations.add(ContactLocation(name: part));
      }
    }

    return locations;
  }

  /// Format contact to file content
  String formatContactFile(Contact contact) {
    final buffer = StringBuffer();

    // Header
    buffer.writeln('# CONTACT: ${contact.displayName}');
    buffer.writeln();

    // Required fields
    buffer.writeln('CALLSIGN: ${contact.callsign}');
    buffer.writeln('NPUB: ${contact.npub}');
    buffer.writeln('CREATED: ${contact.created}');
    buffer.writeln('FIRST_SEEN: ${contact.firstSeen}');
    buffer.writeln();

    // Optional contact information
    for (var email in contact.emails) {
      buffer.writeln('EMAIL: $email');
    }
    for (var phone in contact.phones) {
      buffer.writeln('PHONE: $phone');
    }
    for (var address in contact.addresses) {
      buffer.writeln('ADDRESS: $address');
    }
    for (var website in contact.websites) {
      buffer.writeln('WEBSITE: $website');
    }

    if (contact.locations.isNotEmpty) {
      buffer.write('LOCATIONS: ');
      buffer.writeln(contact.locations.map((l) => l.displayString).join(', '));
    }

    if (contact.profilePicture != null) {
      buffer.writeln('PROFILE_PICTURE: ${contact.profilePicture}');
    }

    if (contact.emails.isNotEmpty || contact.phones.isNotEmpty ||
        contact.addresses.isNotEmpty || contact.websites.isNotEmpty ||
        contact.locations.isNotEmpty || contact.profilePicture != null) {
      buffer.writeln();
    }

    // Identity management
    if (contact.revoked || contact.revocationReason != null ||
        contact.successor != null || contact.previousIdentity != null) {
      buffer.writeln('REVOKED: ${contact.revoked}');
      if (contact.revocationReason != null) {
        buffer.writeln('REVOCATION_REASON: ${contact.revocationReason}');
      }
      if (contact.successor != null) {
        buffer.writeln('SUCCESSOR: ${contact.successor}');
      }
      if (contact.successorSince != null) {
        buffer.writeln('SUCCESSOR_SINCE: ${contact.successorSince}');
      }
      if (contact.previousIdentity != null) {
        buffer.writeln('PREVIOUS_IDENTITY: ${contact.previousIdentity}');
      }
      if (contact.previousIdentitySince != null) {
        buffer.writeln('PREVIOUS_IDENTITY_SINCE: ${contact.previousIdentitySince}');
      }
      buffer.writeln();
    }

    // Notes
    if (contact.notes.isNotEmpty) {
      buffer.writeln(contact.notes);
      buffer.writeln();
    }

    // Metadata
    if (contact.metadataNpub != null) {
      buffer.writeln('--> npub: ${contact.metadataNpub}');
    }
    if (contact.signature != null) {
      buffer.writeln('--> signature: ${contact.signature}');
    }

    return buffer.toString();
  }

  /// Save contact (create or update)
  /// Returns error message if duplicate found, null on success
  Future<String?> saveContact(Contact contact, {String? groupPath}) async {
    if (_collectionPath == null) return 'Collection not initialized';

    // Check for duplicates (callsign and npub)
    final duplicateError = await _checkDuplicates(
      contact.callsign,
      contact.npub,
      excludeFilePath: contact.filePath,
    );
    if (duplicateError != null) {
      return duplicateError;
    }

    final savePath = groupPath != null && groupPath.isNotEmpty
        ? '$_collectionPath/contacts/$groupPath'
        : '$_collectionPath/contacts';

    // Ensure directory exists
    final dir = Directory(savePath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final file = File('$savePath/${contact.callsign}.txt');
    final fileContent = formatContactFile(contact);

    try {
      await file.writeAsString(fileContent);
      print('ContactService: Saved contact ${contact.callsign} to ${file.path}');
      return null; // Success
    } catch (e) {
      print('ContactService: Error saving contact: $e');
      return 'Error saving contact: $e';
    }
  }

  /// Check for duplicate callsign or npub
  /// Returns error message if duplicate found, null if no duplicates
  Future<String?> _checkDuplicates(
    String callsign,
    String npub, {
    String? excludeFilePath,
  }) async {
    final allContacts = await loadAllContactsRecursively();

    for (var contact in allContacts) {
      // Skip the contact we're updating
      if (excludeFilePath != null && contact.filePath == excludeFilePath) {
        continue;
      }

      // Check callsign duplicate
      if (contact.callsign == callsign) {
        final location = (contact.groupPath == null || contact.groupPath!.isEmpty) ? 'root' : contact.groupPath;
        return 'Contact with callsign "$callsign" already exists in $location';
      }

      // Check npub duplicate
      if (contact.npub == npub) {
        final location = (contact.groupPath == null || contact.groupPath!.isEmpty) ? 'root' : contact.groupPath;
        return 'Contact with this NPUB already exists: ${contact.displayName} in $location';
      }
    }

    return null; // No duplicates found
  }

  /// Delete contact
  Future<bool> deleteContact(String callsign, {String? groupPath}) async {
    if (_collectionPath == null) return false;

    final deletePath = groupPath != null && groupPath.isNotEmpty
        ? '$_collectionPath/contacts/$groupPath'
        : '$_collectionPath/contacts';

    final file = File('$deletePath/$callsign.txt');
    if (!await file.exists()) return false;

    try {
      await file.delete();
      print('ContactService: Deleted contact $callsign');

      // Also delete profile picture if exists
      await _deleteProfilePicture(callsign);

      return true;
    } catch (e) {
      print('ContactService: Error deleting contact: $e');
      return false;
    }
  }

  /// Delete profile picture for a contact
  Future<void> _deleteProfilePicture(String callsign) async {
    if (_collectionPath == null) return;

    final pictureDir = Directory('$_collectionPath/contacts/profile-pictures');
    if (!await pictureDir.exists()) return;

    // Check for common image extensions
    final extensions = ['jpg', 'jpeg', 'png', 'gif', 'webp'];
    for (var ext in extensions) {
      final file = File('${pictureDir.path}/$callsign.$ext');
      if (await file.exists()) {
        await file.delete();
        print('ContactService: Deleted profile picture for $callsign');
        break;
      }
    }
  }

  /// Move contact to different group
  Future<bool> moveContact(
    String callsign,
    String? fromGroupPath,
    String? toGroupPath,
  ) async {
    if (_collectionPath == null) return false;

    final fromPath = fromGroupPath != null && fromGroupPath.isNotEmpty
        ? '$_collectionPath/contacts/$fromGroupPath'
        : '$_collectionPath/contacts';

    final toPath = toGroupPath != null && toGroupPath.isNotEmpty
        ? '$_collectionPath/contacts/$toGroupPath'
        : '$_collectionPath/contacts';

    final fromFile = File('$fromPath/$callsign.txt');
    if (!await fromFile.exists()) return false;

    // Ensure destination directory exists
    final toDir = Directory(toPath);
    if (!await toDir.exists()) {
      await toDir.create(recursive: true);
    }

    final toFile = File('$toPath/$callsign.txt');

    try {
      await fromFile.copy(toFile.path);
      await fromFile.delete();
      print('ContactService: Moved contact $callsign from $fromPath to $toPath');
      return true;
    } catch (e) {
      print('ContactService: Error moving contact: $e');
      return false;
    }
  }

  /// Load all groups (folders)
  Future<List<ContactGroup>> loadGroups() async {
    if (_collectionPath == null) return [];

    final groups = <ContactGroup>[];
    final contactsDir = Directory('$_collectionPath/contacts');
    if (!await contactsDir.exists()) return [];

    await _loadGroupsRecursive(contactsDir, '', groups);

    return groups;
  }

  /// Recursively load groups from directory
  Future<void> _loadGroupsRecursive(
    Directory dir,
    String relativePath,
    List<ContactGroup> groups,
  ) async {
    final entities = await dir.list().toList();

    for (var entity in entities) {
      if (entity is Directory) {
        final dirname = entity.path.split('/').last;

        // Skip profile-pictures and hidden directories
        if (dirname == 'profile-pictures' || dirname.startsWith('.')) continue;

        final groupPath = relativePath.isEmpty ? dirname : '$relativePath/$dirname';

        // Count contacts in this group (non-recursive)
        int contactCount = 0;
        final entities = await entity.list().toList();

        for (var file in entities) {
          if (file is File && file.path.endsWith('.txt')) {
            final filename = file.path.split('/').last;
            if (filename != 'group.txt' && !filename.startsWith('.')) {
              contactCount++;
            }
          }
        }

        // Load group metadata if exists
        final groupFile = File('${entity.path}/group.txt');
        String? description;
        String? created;
        String? author;

        if (await groupFile.exists()) {
          final metadata = await _parseGroupFile(groupFile.path);
          description = metadata['description'];
          created = metadata['created'];
          author = metadata['author'];
        }

        groups.add(ContactGroup(
          name: dirname,
          path: groupPath,
          description: description,
          created: created,
          author: author,
          contactCount: contactCount,
        ));

        // Recurse into subdirectories
        await _loadGroupsRecursive(entity, groupPath, groups);
      }
    }
  }

  /// Parse group.txt file
  Future<Map<String, String?>> _parseGroupFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return {};

    final content = await file.readAsString();
    final lines = content.split('\n');

    String? description;
    String? created;
    String? author;
    final descLines = <String>[];
    bool inDescription = false;

    for (var line in lines) {
      final trimmed = line.trim();

      if (trimmed.startsWith('CREATED:')) {
        created = trimmed.substring('CREATED:'.length).trim();
        inDescription = true;
      } else if (trimmed.startsWith('AUTHOR:')) {
        author = trimmed.substring('AUTHOR:'.length).trim();
      } else if (trimmed.startsWith('-->')) {
        break; // End of content
      } else if (inDescription && trimmed.isNotEmpty && !trimmed.startsWith('#')) {
        descLines.add(line);
      }
    }

    if (descLines.isNotEmpty) {
      description = descLines.join('\n').trim();
    }

    return {
      'description': description,
      'created': created,
      'author': author,
    };
  }

  /// Create new group
  Future<bool> createGroup(String groupPath, {
    String? description,
    String? author,
  }) async {
    if (_collectionPath == null) return false;

    final dir = Directory('$_collectionPath/contacts/$groupPath');
    if (await dir.exists()) {
      print('ContactService: Group already exists: $groupPath');
      return false;
    }

    try {
      await dir.create(recursive: true);

      // Create group.txt if description or author provided
      if (description != null || author != null) {
        final groupFile = File('${dir.path}/group.txt');
        final buffer = StringBuffer();

        buffer.writeln('# GROUP: ${groupPath.split('/').last}');
        buffer.writeln();

        final now = DateTime.now();
        final timestamp = '${now.year.toString().padLeft(4, '0')}-'
            '${now.month.toString().padLeft(2, '0')}-'
            '${now.day.toString().padLeft(2, '0')} '
            '${now.hour.toString().padLeft(2, '0')}:'
            '${now.minute.toString().padLeft(2, '0')}_'
            '${now.second.toString().padLeft(2, '0')}';

        buffer.writeln('CREATED: $timestamp');
        if (author != null) {
          buffer.writeln('AUTHOR: $author');
        }
        buffer.writeln();

        if (description != null) {
          buffer.writeln(description);
          buffer.writeln();
        }

        await groupFile.writeAsString(buffer.toString());
      }

      print('ContactService: Created group $groupPath');
      return true;
    } catch (e) {
      print('ContactService: Error creating group: $e');
      return false;
    }
  }

  /// Delete group (only if empty)
  Future<bool> deleteGroup(String groupPath) async {
    if (_collectionPath == null) return false;

    final dir = Directory('$_collectionPath/contacts/$groupPath');
    if (!await dir.exists()) return false;

    // Check if group has any contacts
    int contactCount = 0;
    final entities = await dir.list().toList();

    for (var entity in entities) {
      if (entity is File && entity.path.endsWith('.txt')) {
        final filename = entity.path.split('/').last;
        if (filename != 'group.txt' && !filename.startsWith('.')) {
          contactCount++;
        }
      } else if (entity is Directory && !entity.path.split('/').last.startsWith('.')) {
        // Has subdirectories
        return false;
      }
    }

    if (contactCount > 0) {
      print('ContactService: Cannot delete non-empty group $groupPath');
      return false;
    }

    try {
      await dir.delete(recursive: true);
      print('ContactService: Deleted group $groupPath');
      return true;
    } catch (e) {
      print('ContactService: Error deleting group: $e');
      return false;
    }
  }

  /// Get profile picture file for a contact
  File? getProfilePictureFile(String callsign) {
    if (_collectionPath == null) return null;

    final extensions = ['jpg', 'jpeg', 'png', 'gif', 'webp'];
    for (var ext in extensions) {
      final file = File('$_collectionPath/contacts/profile-pictures/$callsign.$ext');
      if (file.existsSync()) {
        return file;
      }
    }
    return null;
  }

  /// Save profile picture for a contact
  Future<String?> saveProfilePicture(String callsign, File sourceFile) async {
    if (_collectionPath == null) return null;

    final pictureDir = Directory('$_collectionPath/contacts/profile-pictures');
    if (!await pictureDir.exists()) {
      await pictureDir.create(recursive: true);
    }

    // Get file extension
    final extension = sourceFile.path.split('.').last.toLowerCase();
    final targetFile = File('${pictureDir.path}/$callsign.$extension');

    try {
      await sourceFile.copy(targetFile.path);
      print('ContactService: Saved profile picture for $callsign');
      return '$callsign.$extension'; // Return filename for PROFILE_PICTURE field
    } catch (e) {
      print('ContactService: Error saving profile picture: $e');
      return null;
    }
  }
}
