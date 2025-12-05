/// Stub file for dart:io on web platform
/// This provides minimal stubs to allow compilation on web

// ignore_for_file: avoid_classes_with_only_static_members

import 'dart:async';
import 'dart:typed_data';

/// Stub for stderr (web platform)
final stderr = _StderrStub();

class _StderrStub {
  void writeln([Object? object]) {
    print('[stderr] $object');
  }

  void write([Object? object]) {
    print('[stderr] $object');
  }
}

/// Stub for FileStat
class FileStat {
  final FileSystemEntityType type;
  final DateTime changed;
  final DateTime modified;
  final DateTime accessed;
  final int size;
  final int mode;

  FileStat._({
    required this.type,
    required this.changed,
    required this.modified,
    required this.accessed,
    required this.size,
    required this.mode,
  });

  static FileStat statSync(String path) {
    return FileStat._(
      type: FileSystemEntityType.notFound,
      changed: DateTime.now(),
      modified: DateTime.now(),
      accessed: DateTime.now(),
      size: 0,
      mode: 0,
    );
  }

  static Future<FileStat> stat(String path) async {
    return statSync(path);
  }
}

/// Stub for FileSystemEntityType
enum FileSystemEntityType {
  file,
  directory,
  link,
  notFound,
  pipe,
  unixDomainSock,
}

/// Stub for FileSystemEvent
class FileSystemEvent {
  final String path;
  final bool isDirectory;
  final int type;

  FileSystemEvent._(this.path, this.isDirectory, this.type);

  static const int create = 1;
  static const int modify = 2;
  static const int delete = 4;
  static const int move = 8;
  static const int all = 15;
}

/// Stub for FileSystemEntity
abstract class FileSystemEntity {
  String get path;
  Directory get parent;
  Uri get uri;

  Future<bool> exists();
  bool existsSync();
  Future<FileSystemEntity> delete({bool recursive = false});
  void deleteSync({bool recursive = false});
  Future<FileSystemEntity> rename(String newPath);
  FileSystemEntity renameSync(String newPath);
  Future<FileStat> stat();
  FileStat statSync();

  static bool isFileSync(String path) => false;
  static bool isDirectorySync(String path) => false;
  static bool isLinkSync(String path) => false;

  static Future<bool> isFile(String path) async => false;
  static Future<bool> isDirectory(String path) async => false;
  static Future<bool> isLink(String path) async => false;

  static Future<FileSystemEntityType> type(String path, {bool followLinks = true}) async {
    return FileSystemEntityType.notFound;
  }

  static FileSystemEntityType typeSync(String path, {bool followLinks = true}) {
    return FileSystemEntityType.notFound;
  }
}

/// Stub for File class
class File implements FileSystemEntity {
  @override
  final String path;

  File(this.path);

  @override
  Directory get parent => Directory(path.substring(0, path.lastIndexOf('/')));

  @override
  Uri get uri => Uri.file(path);

  @override
  Future<bool> exists() async => false;

  @override
  bool existsSync() => false;

  Future<String> readAsString() async {
    throw UnsupportedError('File operations are not supported on web');
  }

  String readAsStringSync() {
    throw UnsupportedError('File operations are not supported on web');
  }

  Future<Uint8List> readAsBytes() async {
    throw UnsupportedError('File operations are not supported on web');
  }

  Uint8List readAsBytesSync() {
    throw UnsupportedError('File operations are not supported on web');
  }

  Future<List<String>> readAsLines() async {
    throw UnsupportedError('File operations are not supported on web');
  }

  Future<File> writeAsString(String contents, {FileMode mode = FileMode.write, bool flush = false}) async {
    throw UnsupportedError('File operations are not supported on web');
  }

  void writeAsStringSync(String contents, {FileMode mode = FileMode.write, bool flush = false}) {
    throw UnsupportedError('File operations are not supported on web');
  }

  Future<File> writeAsBytes(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false}) async {
    throw UnsupportedError('File operations are not supported on web');
  }

  void writeAsBytesSync(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false}) {
    throw UnsupportedError('File operations are not supported on web');
  }

  Future<File> copy(String newPath) async {
    throw UnsupportedError('File operations are not supported on web');
  }

  File copySync(String newPath) {
    throw UnsupportedError('File operations are not supported on web');
  }

  @override
  Future<File> delete({bool recursive = false}) async {
    throw UnsupportedError('File operations are not supported on web');
  }

  @override
  void deleteSync({bool recursive = false}) {
    throw UnsupportedError('File operations are not supported on web');
  }

  @override
  Future<File> rename(String newPath) async {
    throw UnsupportedError('File operations are not supported on web');
  }

  @override
  File renameSync(String newPath) {
    throw UnsupportedError('File operations are not supported on web');
  }

  IOSink openWrite({FileMode mode = FileMode.write}) {
    throw UnsupportedError('File operations are not supported on web');
  }

  Future<int> length() async => 0;

  int lengthSync() => 0;

  Future<DateTime> lastModified() async => DateTime.now();

  DateTime lastModifiedSync() => DateTime.now();

  @override
  Future<FileStat> stat() async => FileStat.stat(path);

  @override
  FileStat statSync() => FileStat.statSync(path);

  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    throw UnsupportedError('File operations are not supported on web');
  }

  void createSync({bool recursive = false, bool exclusive = false}) {
    throw UnsupportedError('File operations are not supported on web');
  }
}

/// Stub for Directory class
class Directory implements FileSystemEntity {
  @override
  final String path;

  Directory(this.path);

  @override
  Directory get parent {
    final lastSlash = path.lastIndexOf('/');
    if (lastSlash <= 0) return Directory('/');
    return Directory(path.substring(0, lastSlash));
  }

  @override
  Uri get uri => Uri.directory(path);

  @override
  Future<bool> exists() async => false;

  @override
  bool existsSync() => false;

  Future<Directory> create({bool recursive = false}) async {
    // Silently succeed on web (directories don't exist but we don't want to crash)
    return this;
  }

  void createSync({bool recursive = false}) {
    // Silently succeed on web
  }

  @override
  Future<Directory> delete({bool recursive = false}) async {
    throw UnsupportedError('Directory operations are not supported on web');
  }

  @override
  void deleteSync({bool recursive = false}) {
    throw UnsupportedError('Directory operations are not supported on web');
  }

  @override
  Future<Directory> rename(String newPath) async {
    throw UnsupportedError('Directory operations are not supported on web');
  }

  @override
  Directory renameSync(String newPath) {
    throw UnsupportedError('Directory operations are not supported on web');
  }

  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) {
    return const Stream.empty();
  }

  List<FileSystemEntity> listSync({bool recursive = false, bool followLinks = true}) {
    return [];
  }

  /// Watch for file system changes (returns empty stream on web)
  Stream<FileSystemEvent> watch({int events = FileSystemEvent.all, bool recursive = false}) {
    return const Stream.empty();
  }

  @override
  Future<FileStat> stat() async => FileStat.stat(path);

  @override
  FileStat statSync() => FileStat.statSync(path);

  static Directory get current => Directory('.');

  static set current(dynamic path) {
    // No-op on web
  }

  static Directory get systemTemp => Directory('/tmp');
}

/// Stub for FileMode enum
enum FileMode {
  read,
  write,
  append,
  writeOnly,
  writeOnlyAppend,
}

/// Stub for IOSink class
class IOSink {
  void writeln([Object? object = '']) {
    print('[IOSink] $object');
  }

  void write(Object? object) {
    print('[IOSink] $object');
  }

  void writeAll(Iterable objects, [String separator = '']) {
    print('[IOSink] ${objects.join(separator)}');
  }

  void add(List<int> data) {
    // No-op on web
  }

  void addError(Object error, [StackTrace? stackTrace]) {
    print('[IOSink Error] $error');
  }

  Future<void> flush() async {}

  Future<void> close() async {}

  Future get done => Future.value();
}

/// Stub for Platform class
class Platform {
  static bool get isLinux => false;
  static bool get isMacOS => false;
  static bool get isWindows => false;
  static bool get isAndroid => false;
  static bool get isIOS => false;
  static bool get isFuchsia => false;

  static String get operatingSystem => 'web';
  static String get operatingSystemVersion => 'web';
  static String get localHostname => 'localhost';
  static String get pathSeparator => '/';
  static int get numberOfProcessors => 1;

  static Map<String, String> get environment => {};
  static String get localeName => 'en_US';
  static String? get executable => null;
  static String get resolvedExecutable => '';
  static List<String> get executableArguments => [];
  static String? get packageConfig => null;
  static Uri get script => Uri.parse('web://');
  static String get version => 'web';
}

/// Stub for InternetAddress
class InternetAddress {
  final String address;
  final String host;
  final InternetAddressType type;

  InternetAddress(this.address)
      : host = address,
        type = InternetAddressType.IPv4;

  static InternetAddress get loopbackIPv4 => InternetAddress('127.0.0.1');
  static InternetAddress get loopbackIPv6 => InternetAddress('::1');
  static InternetAddress get anyIPv4 => InternetAddress('0.0.0.0');
  static InternetAddress get anyIPv6 => InternetAddress('::');

  static Future<List<InternetAddress>> lookup(String host, {InternetAddressType type = InternetAddressType.any}) async {
    return [];
  }
}

/// Stub for HttpServer
class HttpServer {
  final InternetAddress address;
  final int port;

  HttpServer._(this.address, this.port);

  static Future<HttpServer> bind(dynamic address, int port, {int backlog = 0, bool v6Only = false, bool shared = false}) async {
    throw UnsupportedError('HttpServer is not supported on web');
  }

  Future<void> close({bool force = false}) async {}

  Stream<HttpRequest> get stream => const Stream.empty();

  StreamSubscription<HttpRequest> listen(void Function(HttpRequest event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    throw UnsupportedError('HttpServer is not supported on web');
  }
}

/// Stub for ProcessSignal
class ProcessSignal {
  static const ProcessSignal sigint = ProcessSignal._('SIGINT');
  static const ProcessSignal sigterm = ProcessSignal._('SIGTERM');
  static const ProcessSignal sighup = ProcessSignal._('SIGHUP');
  static const ProcessSignal sigkill = ProcessSignal._('SIGKILL');

  final String _name;
  const ProcessSignal._(this._name);

  Stream<ProcessSignal> watch() => const Stream.empty();

  @override
  String toString() => _name;
}

/// Stub for InternetAddressType
class InternetAddressType {
  static const InternetAddressType IPv4 = InternetAddressType._('IPv4');
  static const InternetAddressType IPv6 = InternetAddressType._('IPv6');
  static const InternetAddressType any = InternetAddressType._('any');
  static const InternetAddressType unix = InternetAddressType._('unix');

  final String _name;
  const InternetAddressType._(this._name);

  @override
  String toString() => _name;
}

/// Stub for NetworkInterface
class NetworkInterface {
  final String name;
  final int index;
  final List<InternetAddress> addresses;

  NetworkInterface._(this.name, this.index, this.addresses);

  static Future<List<NetworkInterface>> list({
    bool includeLoopback = false,
    bool includeLinkLocal = false,
    InternetAddressType type = InternetAddressType.any,
  }) async {
    // Return empty list on web
    return [];
  }
}

/// Stub for Process
class Process {
  static Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    throw UnsupportedError('Process is not supported on web');
  }

  static Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
  }) async {
    throw UnsupportedError('Process is not supported on web');
  }

  static ProcessResult runSync(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
  }) {
    throw UnsupportedError('Process is not supported on web');
  }

  static bool killPid(int pid, [ProcessSignal signal = ProcessSignal.sigterm]) {
    return false;
  }
}

/// Stub for ProcessResult
class ProcessResult {
  final int exitCode;
  final dynamic stdout;
  final dynamic stderr;
  final int pid;

  ProcessResult(this.pid, this.exitCode, this.stdout, this.stderr);
}

/// Stub for ProcessStartMode
class ProcessStartMode {
  static const normal = ProcessStartMode._('normal');
  static const inheritStdio = ProcessStartMode._('inheritStdio');
  static const detached = ProcessStartMode._('detached');
  static const detachedWithStdio = ProcessStartMode._('detachedWithStdio');

  final String _name;
  const ProcessStartMode._(this._name);
}

/// Stub for Socket
class Socket {
  static Future<Socket> connect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
    Duration? timeout,
  }) async {
    throw UnsupportedError('Socket is not supported on web');
  }
}

/// Stub for GZipCodec
class GZipCodec {
  const GZipCodec();

  List<int> encode(List<int> bytes) {
    throw UnsupportedError('GZipCodec is not supported on web');
  }

  List<int> decode(List<int> bytes) {
    throw UnsupportedError('GZipCodec is not supported on web');
  }
}

const gzip = GZipCodec();

/// Stub for exit
Never exit(int code) {
  throw UnsupportedError('exit is not supported on web');
}

/// Stub for pid
int get pid => 0;

/// Stub for stdin
final stdin = _StdinStub();

class _StdinStub {
  bool echoMode = true;
  bool lineMode = true;

  String? readLineSync() {
    throw UnsupportedError('stdin is not supported on web');
  }

  int readByteSync() {
    throw UnsupportedError('stdin is not supported on web');
  }
}

/// Stub for stdout
final stdout = _StdoutStub();

class _StdoutStub {
  void writeln([Object? object]) {
    print('$object');
  }

  void write(Object? object) {
    print('$object');
  }

  void writeAll(Iterable objects, [String separator = '']) {
    print(objects.join(separator));
  }

  int get terminalColumns => 80;
  int get terminalLines => 24;
  bool get hasTerminal => false;
  bool get supportsAnsiEscapes => false;
}

/// Stub for sleep
void sleep(Duration duration) {
  // Cannot truly sleep in web, but we can provide a no-op
}

/// Stub for HttpClient
class HttpClient {
  Duration? connectionTimeout;
  Duration? idleTimeout;
  int? maxConnectionsPerHost;
  bool autoUncompress = true;
  String? userAgent;

  HttpClient();

  Future<HttpClientRequest> getUrl(Uri url) async {
    throw UnsupportedError('HttpClient is not supported on web');
  }

  Future<HttpClientRequest> postUrl(Uri url) async {
    throw UnsupportedError('HttpClient is not supported on web');
  }

  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    throw UnsupportedError('HttpClient is not supported on web');
  }

  void close({bool force = false}) {}
}

/// Stub for HttpClientRequest
abstract class HttpClientRequest {
  HttpHeaders get headers;
  List<int> get contentLength;
  Future<HttpClientResponse> close();
}

/// Stub for HttpClientResponse
abstract class HttpClientResponse {
  int get statusCode;
  String get reasonPhrase;
  HttpHeaders get headers;
}

/// Stub for HttpHeaders
abstract class HttpHeaders {
  static const acceptHeader = 'accept';
  static const contentTypeHeader = 'content-type';
  static const contentLengthHeader = 'content-length';

  ContentType? contentType;

  void add(String name, Object value);
  void set(String name, Object value);
  String? value(String name);
  List<String>? operator [](String name);
}

/// Stub for ContentType
class ContentType {
  final String primaryType;
  final String subType;
  final String? charset;

  ContentType(this.primaryType, this.subType, {this.charset});

  static ContentType parse(String value) {
    final parts = value.split('/');
    return ContentType(parts.isNotEmpty ? parts[0] : '', parts.length > 1 ? parts[1] : '');
  }

  static final json = ContentType('application', 'json');
  static final text = ContentType('text', 'plain');
  static final html = ContentType('text', 'html');
  static final binary = ContentType('application', 'octet-stream');

  String get mimeType => '$primaryType/$subType';

  @override
  String toString() => charset != null ? '$mimeType; charset=$charset' : mimeType;
}

/// Stub for Link (symlink)
class Link implements FileSystemEntity {
  @override
  final String path;

  Link(this.path);

  @override
  Directory get parent => Directory(path.substring(0, path.lastIndexOf('/')));

  @override
  Uri get uri => Uri.file(path);

  @override
  Future<bool> exists() async => false;

  @override
  bool existsSync() => false;

  @override
  Future<Link> delete({bool recursive = false}) async {
    throw UnsupportedError('Link operations are not supported on web');
  }

  @override
  void deleteSync({bool recursive = false}) {
    throw UnsupportedError('Link operations are not supported on web');
  }

  @override
  Future<Link> rename(String newPath) async {
    throw UnsupportedError('Link operations are not supported on web');
  }

  @override
  Link renameSync(String newPath) {
    throw UnsupportedError('Link operations are not supported on web');
  }

  @override
  Future<FileStat> stat() async => FileStat.stat(path);

  @override
  FileStat statSync() => FileStat.statSync(path);

  Future<Link> create(String target, {bool recursive = false}) async {
    throw UnsupportedError('Link operations are not supported on web');
  }

  void createSync(String target, {bool recursive = false}) {
    throw UnsupportedError('Link operations are not supported on web');
  }

  Future<String> target() async {
    throw UnsupportedError('Link operations are not supported on web');
  }

  String targetSync() {
    throw UnsupportedError('Link operations are not supported on web');
  }
}

/// Stub for IOException
class IOException implements Exception {
  final String message;
  final OSError? osError;

  IOException(this.message, {this.osError});

  @override
  String toString() => message;
}

/// Stub for FileSystemException
class FileSystemException implements IOException {
  @override
  final String message;
  final String? path;
  @override
  final OSError? osError;

  FileSystemException([this.message = '', this.path, this.osError]);

  @override
  String toString() => 'FileSystemException: $message, path = $path';
}

/// Stub for OSError
class OSError {
  final String message;
  final int errorCode;

  const OSError([this.message = '', this.errorCode = -1]);

  static const int noErrorCode = -1;

  @override
  String toString() => 'OS Error: $message, errno = $errorCode';
}

/// Stub for SocketException
class SocketException implements IOException {
  @override
  final String message;
  @override
  final OSError? osError;
  final InternetAddress? address;
  final int? port;

  SocketException(this.message, {this.osError, this.address, this.port});

  @override
  String toString() => 'SocketException: $message';
}

/// Stub for WebSocket
class WebSocket {
  static const int connecting = 0;
  static const int open = 1;
  static const int closing = 2;
  static const int closed = 3;

  int get readyState => closed;
  String? get closeReason => null;
  int? get closeCode => null;

  static Future<WebSocket> connect(String url, {Iterable<String>? protocols, Map<String, dynamic>? headers}) async {
    throw UnsupportedError('WebSocket is not supported on web via dart:io');
  }

  void add(dynamic data) {
    throw UnsupportedError('WebSocket is not supported on web via dart:io');
  }

  Future<void> close([int? code, String? reason]) async {}

  Stream<dynamic> get stream => const Stream.empty();

  StreamSubscription<dynamic> listen(void Function(dynamic event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    throw UnsupportedError('WebSocket is not supported on web via dart:io');
  }
}

/// Stub for WebSocketTransformer
class WebSocketTransformer {
  static bool isUpgradeRequest(HttpRequest request) => false;

  static Future<WebSocket> upgrade(HttpRequest request) async {
    throw UnsupportedError('WebSocketTransformer is not supported on web');
  }
}

/// Stub for HttpRequest
abstract class HttpRequest {
  Uri get uri;
  String get method;
  HttpHeaders get headers;
  HttpResponse get response;
  HttpSession get session;
  String get protocolVersion;
  InternetAddress get connectionInfo;
  List<Cookie> get cookies;
  int get contentLength;
  bool get persistentConnection;
  X509Certificate? get certificate;

  StreamSubscription<List<int>> listen(void Function(List<int> event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError});
}

/// Stub for HttpResponse
abstract class HttpResponse {
  int get statusCode;
  set statusCode(int value);
  String get reasonPhrase;
  set reasonPhrase(String value);
  HttpHeaders get headers;
  List<Cookie> get cookies;
  Duration? get deadline;
  set deadline(Duration? value);
  int get contentLength;
  set contentLength(int value);
  bool get persistentConnection;
  set persistentConnection(bool value);
  bool get bufferOutput;
  set bufferOutput(bool value);

  void add(List<int> data);
  void write(Object? object);
  void writeln([Object? object]);
  void writeAll(Iterable objects, [String separator]);
  Future<void> close();
  Future<void> flush();
  Future<void> redirect(Uri location, {int status});
  Future<dynamic> addStream(Stream<List<int>> stream);
}

/// Stub for HttpSession
abstract class HttpSession {
  String get id;
  bool get isNew;
  void destroy();
  void set onTimeout(void Function() callback);
}

/// Stub for Cookie
class Cookie {
  String name;
  String value;
  DateTime? expires;
  int? maxAge;
  String? domain;
  String? path;
  bool secure;
  bool httpOnly;

  Cookie(this.name, this.value)
      : secure = false,
        httpOnly = false;

  Cookie.fromSetCookieValue(String value)
      : name = '',
        value = '',
        secure = false,
        httpOnly = false;

  @override
  String toString() => '$name=$value';
}

/// Stub for X509Certificate
abstract class X509Certificate {
  String get subject;
  String get issuer;
  DateTime get startValidity;
  DateTime get endValidity;
}

/// Stub for HttpConnectionInfo
abstract class HttpConnectionInfo {
  InternetAddress get remoteAddress;
  int get remotePort;
  int get localPort;
}
