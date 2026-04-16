/*
 * Conditional factory that returns the right ProfileStorage
 * implementation for the current target. Native (desktop / mobile)
 * hits profile_storage_io.dart and wraps a real filesystem path;
 * web hits profile_storage_web.dart and returns a
 * MemoryProfileStorage rooted at the same virtual path.
 *
 * Every caller that previously constructed a
 * FilesystemProfileStorage directly now goes through
 * [makeFilesystemStorage] so the dart:io import stays isolated.
 */

export 'profile_storage_web.dart'
    if (dart.library.io) 'profile_storage_io.dart';
