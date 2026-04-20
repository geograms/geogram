import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:shared_storage/shared_storage.dart' as saf;

/// One backup file in the user's chosen folder. Used for listings.
class BackupStoreEntry {
  /// Display name including extension, e.g. "geogram-backup-X1ABC-2026-04-19-101530.zip".
  final String name;

  /// Opaque locator. On the filesystem this is the absolute path; on Android
  /// SAF this is the document URI as a string. Treat as a token to pass back
  /// into [BackupStore] methods, not as a real path.
  final String locator;

  /// Bytes on disk; null when the underlying provider couldn't report it.
  final int? sizeBytes;

  /// Last-modified timestamp; null when unknown.
  final DateTime? modifiedAt;

  const BackupStoreEntry({
    required this.name,
    required this.locator,
    this.sizeBytes,
    this.modifiedAt,
  });
}

/// Abstraction over the destination folder for local backups. Two
/// implementations: a plain dart:io filesystem store (desktop, and Android
/// when the user picks a real path under the app sandbox), and a Storage
/// Access Framework (SAF) store backed by a content:// tree URI on Android
/// for any user-picked folder outside the sandbox.
///
/// Operations on the *backup folder* go through this abstraction.
/// Operations on the *profile data* (reading/writing files inside the
/// app's own data dir) keep using dart:io directly — they don't need SAF.
abstract class BackupStore {
  /// Verify the destination is reachable + writable. Returns null on
  /// success, or a human-readable error string.
  Future<String?> validate();

  /// List backup zip files in the folder.
  Future<List<BackupStoreEntry>> list();

  /// Write [bytes] as a new file named [name]. Returns the locator of the
  /// newly created file (path or content URI string).
  Future<String> writeBytes(String name, Uint8List bytes);

  /// Read all bytes of a previously listed entry.
  Future<Uint8List> readBytes(String locator);

  /// Delete the entry at [locator]. Returns true on success.
  Future<bool> delete(String locator);

  /// User-friendly label for the destination, e.g. the path or the SAF
  /// tree's last-segment name.
  String displayLabel();

  /// Open the right backend for [pathOrUri] — SAF on Android when the value
  /// looks like a content URI, plain filesystem otherwise.
  static BackupStore openFor(String pathOrUri) {
    if (pathOrUri.startsWith('content://')) {
      return SafBackupStore(Uri.parse(pathOrUri));
    }
    return FilesystemBackupStore(pathOrUri);
  }
}

class FilesystemBackupStore implements BackupStore {
  final String path;

  FilesystemBackupStore(this.path);

  @override
  Future<String?> validate() async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      // Try a probe write to detect read-only mounts / scoped-storage refusal.
      final probe = File(p.join(path, '.geogram-write-probe'));
      await probe.writeAsString('ok');
      await probe.delete();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  @override
  Future<List<BackupStoreEntry>> list() async {
    final dir = Directory(path);
    if (!await dir.exists()) return const [];
    final out = <BackupStoreEntry>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.startsWith('geogram-backup-') || !name.endsWith('.zip')) continue;
      try {
        final stat = await entity.stat();
        out.add(BackupStoreEntry(
          name: name,
          locator: entity.path,
          sizeBytes: stat.size,
          modifiedAt: stat.modified,
        ));
      } catch (_) {
        // Skip unreadable entries
      }
    }
    return out;
  }

  @override
  Future<String> writeBytes(String name, Uint8List bytes) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final out = File(p.join(path, name));
    await out.writeAsBytes(bytes, flush: true);
    return out.path;
  }

  @override
  Future<Uint8List> readBytes(String locator) async {
    return await File(locator).readAsBytes();
  }

  @override
  Future<bool> delete(String locator) async {
    final f = File(locator);
    if (!await f.exists()) return false;
    await f.delete();
    return true;
  }

  @override
  String displayLabel() => path;
}

class SafBackupStore implements BackupStore {
  /// content:// tree URI for the picked folder (returned by
  /// [saf.openDocumentTree]).
  final Uri treeUri;

  SafBackupStore(this.treeUri);

  @override
  Future<String?> validate() async {
    try {
      final persisted = await saf.isPersistedUri(treeUri);
      if (!persisted) {
        return 'No persisted permission for $treeUri — please re-pick the folder';
      }
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  @override
  Future<List<BackupStoreEntry>> list() async {
    final out = <BackupStoreEntry>[];
    try {
      final stream = saf.listFiles(treeUri, columns: const [
        saf.DocumentFileColumn.displayName,
        saf.DocumentFileColumn.size,
        saf.DocumentFileColumn.lastModified,
        saf.DocumentFileColumn.mimeType,
      ]);
      await for (final doc in stream) {
        final name = doc.name;
        if (name == null) continue;
        if (!name.startsWith('geogram-backup-') || !name.endsWith('.zip')) {
          continue;
        }
        out.add(BackupStoreEntry(
          name: name,
          locator: doc.uri.toString(),
          sizeBytes: doc.size,
          modifiedAt: doc.lastModified,
        ));
      }
    } catch (_) {
      // Returns whatever we managed to enumerate
    }
    return out;
  }

  @override
  Future<String> writeBytes(String name, Uint8List bytes) async {
    final created = await saf.createFileAsBytes(
      treeUri,
      mimeType: 'application/zip',
      displayName: name,
      bytes: bytes,
    );
    if (created == null) {
      throw const FileSystemException('SAF createFile returned null');
    }
    return created.uri.toString();
  }

  @override
  Future<Uint8List> readBytes(String locator) async {
    final uri = Uri.parse(locator);
    final bytes = await saf.getDocumentContent(uri);
    if (bytes == null) {
      throw FileSystemException('SAF readBytes returned null', locator);
    }
    return bytes;
  }

  @override
  Future<bool> delete(String locator) async {
    final uri = Uri.parse(locator);
    final ok = await saf.delete(uri);
    return ok ?? false;
  }

  @override
  String displayLabel() {
    // The tree URI ends with .../tree/<root>%3A<path>. Show a shortened
    // version that's recognisable in the UI.
    final raw = Uri.decodeFull(treeUri.toString());
    final i = raw.lastIndexOf('/tree/');
    return i >= 0 ? raw.substring(i + '/tree/'.length) : raw;
  }
}
