/// Log service with conditional implementation
/// Uses stub (console-only) on web/CLI, native (file-based) on native Flutter apps
export 'log_service_stub.dart'
    if (dart.library.io) 'log_service_native.dart';
