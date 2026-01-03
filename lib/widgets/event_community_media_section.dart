/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io' as io;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';

import '../connection/connection_manager.dart';
import '../models/event.dart';
import '../services/i18n_service.dart';
import '../services/station_service.dart';
import '../platform/file_image_helper.dart' as file_helper;
import '../pages/photo_viewer_page.dart';

class EventCommunityMediaSection extends StatefulWidget {
  final Event event;
  final String collectionPath;
  final String? currentCallsign;
  final String? currentUserNpub;

  const EventCommunityMediaSection({
    Key? key,
    required this.event,
    required this.collectionPath,
    required this.currentCallsign,
    required this.currentUserNpub,
  }) : super(key: key);

  @override
  State<EventCommunityMediaSection> createState() => _EventCommunityMediaSectionState();
}

class _ContributorMediaEntry {
  final String callsign;
  final List<_MediaFileEntry> imageFiles;
  final List<_MediaFileEntry> otherFiles;
  final bool isApproved;
  final bool isBanned;

  const _ContributorMediaEntry({
    required this.callsign,
    required this.imageFiles,
    required this.otherFiles,
    required this.isApproved,
    required this.isBanned,
  });

  List<_MediaFileEntry> get allFiles => [...imageFiles, ...otherFiles];
}

class _MediaFileEntry {
  final String name;
  final String path;
  final bool isImage;
  final bool isVideo;
  final bool isRemote;

  const _MediaFileEntry({
    required this.name,
    required this.path,
    required this.isImage,
    required this.isVideo,
    required this.isRemote,
  });

  bool get isMedia => isImage || isVideo;
}

class _StationConnectionInfo {
  final String? callsign;
  final String? baseUrl;

  const _StationConnectionInfo({
    required this.callsign,
    required this.baseUrl,
  });
}

class _StationApiResponse {
  final int statusCode;
  final dynamic data;

  const _StationApiResponse({
    required this.statusCode,
    this.data,
  });
}

class _EventCommunityMediaSectionState extends State<EventCommunityMediaSection> {
  final I18nService _i18n = I18nService();

  bool _isLoading = true;
  bool _isUploading = false;
  List<_ContributorMediaEntry> _contributors = [];
  Set<String> _approved = {};
  Set<String> _banned = {};
  String? _stationError;
  _StationConnectionInfo? _stationConnection;
  final Map<String, String> _cachedRemoteFiles = {};
  final Map<String, Future<String?>> _remoteFileFutures = {};

  bool get _isPublic => widget.event.visibility.toLowerCase() == 'public';
  bool get _isGroup => widget.event.visibility.toLowerCase() == 'group';
  bool get _supportsMedia => _isPublic || _isGroup;
  bool get _useStation => _isPublic;

  bool get _canModerate => _isPublic &&
      widget.event.canModerate(widget.currentCallsign ?? '', widget.currentUserNpub);

  String? get _eventPath {
    if (widget.collectionPath.isEmpty) return null;
    final year = widget.event.id.substring(0, 4);
    return '${widget.collectionPath}/$year/${widget.event.id}';
  }

  String? get _mediaRoot {
    final eventPath = _eventPath;
    if (eventPath == null) return null;
    return '$eventPath/media';
  }

  String? get _approvedFilePath {
    final root = _mediaRoot;
    if (!_isPublic || root == null) return null;
    return '$root/approved.txt';
  }

  String? get _bannedFilePath {
    final root = _mediaRoot;
    if (!_isPublic || root == null) return null;
    return '$root/banned.txt';
  }

  @override
  void initState() {
    super.initState();
    _loadContributions();
  }

  @override
  void didUpdateWidget(covariant EventCommunityMediaSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.id != widget.event.id ||
        oldWidget.collectionPath != widget.collectionPath ||
        oldWidget.event.visibility != widget.event.visibility) {
      _loadContributions();
    }
  }

  Future<void> _loadContributions() async {
    if (!_supportsMedia || kIsWeb) {
      setState(() {
        _isLoading = false;
        _contributors = [];
        _stationError = null;
      });
      return;
    }

    setState(() => _isLoading = true);
    _cachedRemoteFiles.clear();
    _remoteFileFutures.clear();

    if (_useStation) {
      await _loadStationContributions();
    } else {
      await _loadLocalContributions();
    }
  }

  Future<void> _loadLocalContributions() async {
    final mediaRoot = _mediaRoot;
    if (mediaRoot == null) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _contributors = [];
      });
      return;
    }

    final approved = _isPublic ? await _readList(_approvedFilePath) : <String>{};
    final banned = _isPublic ? await _readList(_bannedFilePath) : <String>{};
    final contributors = <_ContributorMediaEntry>[];

    try {
      final rootDir = io.Directory(mediaRoot);
      if (await rootDir.exists()) {
        await for (final entity in rootDir.list()) {
          if (entity is! io.Directory) continue;
          final callsign = path.basename(entity.path);
          if (callsign.isEmpty) continue;

          final files = <_MediaFileEntry>[];
          await for (final entry in entity.list()) {
            if (entry is io.File) {
              final name = path.basename(entry.path);
              if (name.startsWith('.')) continue;
              files.add(_MediaFileEntry(
                name: name,
                path: entry.path,
                isImage: _isImageFile(entry.path),
                isVideo: _isVideoFile(entry.path),
                isRemote: false,
              ));
            }
          }

          if (files.isEmpty) continue;
          files.sort((a, b) => a.name.compareTo(b.name));

          final imageFiles = files.where((file) => file.isMedia).toList();
          final otherFiles = files.where((file) => !file.isMedia).toList();
          final isApproved = _isPublic ? approved.contains(callsign) : true;
          final isBanned = _isPublic ? banned.contains(callsign) : false;

          contributors.add(_ContributorMediaEntry(
            callsign: callsign,
            imageFiles: imageFiles,
            otherFiles: otherFiles,
            isApproved: isApproved,
            isBanned: isBanned,
          ));
        }
      }
    } catch (_) {
      // Ignore - leave empty list if we fail to load.
    }

    contributors.sort((a, b) => a.callsign.compareTo(b.callsign));

    if (!mounted) return;
    setState(() {
      _approved = approved;
      _banned = banned;
      _contributors = contributors;
      _isLoading = false;
      _stationError = null;
    });
  }

  Future<void> _loadStationContributions() async {
    if (await _ensureStationConnectionInfo() == null) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _contributors = [];
        _approved = {};
        _banned = {};
        _stationError = _i18n.t('station_required_for_media');
      });
      return;
    }

    final query = <String, String>{};
    if (_canModerate) {
      query['include_pending'] = 'true';
      query['include_banned'] = 'true';
    }

    final queryString = query.isEmpty ? '' : '?${Uri(queryParameters: query).query}';
    final apiPath = '/api/events/${widget.event.id}/media$queryString';

    try {
      final response = await _stationApiRequest(
        method: 'GET',
        path: apiPath,
        headers: {'Accept': 'application/json'},
      );

      if (response == null) {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _contributors = [];
          _stationError = _i18n.t('station_required_for_media');
        });
        return;
      }

      if (response.statusCode != 200) {
        if (!mounted) return;
        if (response.statusCode == 404) {
          setState(() {
            _isLoading = false;
            _contributors = [];
            _approved = {};
            _banned = {};
            _stationError = null;
          });
          return;
        }
        setState(() {
          _isLoading = false;
          _contributors = [];
          _stationError = '${_i18n.t('error')}: ${response.statusCode}';
        });
        return;
      }

      final bodyText = _responseToString(response.data);
      final data = jsonDecode(bodyText) as Map<String, dynamic>;
      final approved = (data['approved'] as List<dynamic>? ?? [])
          .map((value) => value.toString())
          .toSet();
      final banned = (data['banned'] as List<dynamic>? ?? [])
          .map((value) => value.toString())
          .toSet();

      final contributors = <_ContributorMediaEntry>[];
      final contributorsJson = data['contributors'] as List<dynamic>? ?? [];
      for (final entry in contributorsJson) {
        if (entry is! Map<String, dynamic>) continue;
        final callsign = entry['callsign'] as String? ?? '';
        if (callsign.isEmpty) continue;

        final filesJson = entry['files'] as List<dynamic>? ?? [];
        final files = <_MediaFileEntry>[];

        for (final file in filesJson) {
          if (file is! Map<String, dynamic>) continue;
          final name = file['name'] as String? ?? '';
          final pathValue = file['path'] as String? ?? '';
          if (name.isEmpty || pathValue.isEmpty) continue;
          final fileType = file['type'] as String?;
          final isImage = fileType == 'image' || _isImageFile(name);
          final isVideo = fileType == 'video' || _isVideoFile(name);
          files.add(_MediaFileEntry(
            name: name,
            path: pathValue,
            isImage: isImage,
            isVideo: isVideo,
            isRemote: true,
          ));
        }

        if (files.isEmpty) continue;
        files.sort((a, b) => a.name.compareTo(b.name));

        final imageFiles = files.where((file) => file.isMedia).toList();
        final otherFiles = files.where((file) => !file.isMedia).toList();
        final isApproved = entry['is_approved'] is bool
            ? entry['is_approved'] as bool
            : approved.contains(callsign);
        final isBanned = entry['is_banned'] is bool
            ? entry['is_banned'] as bool
            : banned.contains(callsign);

        contributors.add(_ContributorMediaEntry(
          callsign: callsign,
          imageFiles: imageFiles,
          otherFiles: otherFiles,
          isApproved: isApproved,
          isBanned: isBanned,
        ));
      }

      contributors.sort((a, b) => a.callsign.compareTo(b.callsign));

      if (!mounted) return;
      setState(() {
        _approved = approved;
        _banned = banned;
        _contributors = contributors;
        _isLoading = false;
        _stationError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _contributors = [];
        _stationError = '${_i18n.t('error')}: $e';
      });
    }
  }

  Future<Set<String>> _readList(String? filePath) async {
    if (filePath == null || filePath.isEmpty) return <String>{};
    final file = io.File(filePath);
    if (!await file.exists()) return <String>{};
    final content = await file.readAsString();
    return content
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toSet();
  }

  Future<void> _writeList(String? filePath, Set<String> values) async {
    if (filePath == null || filePath.isEmpty) return;
    final file = io.File(filePath);
    await file.parent.create(recursive: true);
    final sorted = values.toList()..sort();
    await file.writeAsString(sorted.join('\n'), flush: true);
  }

  Future<_StationConnectionInfo?> _ensureStationConnectionInfo() async {
    if (_stationConnection != null) return _stationConnection;
    final stationService = StationService();
    if (!stationService.isInitialized) {
      await stationService.initialize();
    }
    final connected = stationService.getConnectedRelay();
    final preferred = stationService.getPreferredStation();
    final station = connected ?? (preferred != null && preferred.url.isNotEmpty ? preferred : null);
    if (station == null || station.url.isEmpty) return null;
    final baseUrl = _normalizeStationUrl(station.url);
    _stationConnection = _StationConnectionInfo(
      callsign: station.callsign != null && station.callsign!.isNotEmpty ? station.callsign : null,
      baseUrl: baseUrl.isNotEmpty ? baseUrl : null,
    );
    return _stationConnection;
  }

  String _normalizeStationUrl(String url) {
    var baseUrl = url;
    if (baseUrl.startsWith('wss://')) {
      baseUrl = baseUrl.replaceFirst('wss://', 'https://');
    } else if (baseUrl.startsWith('ws://')) {
      baseUrl = baseUrl.replaceFirst('ws://', 'http://');
    }
    return baseUrl;
  }

  String _resolveStationUrl(String baseUrl, String pathValue) {
    if (pathValue.startsWith('http://') || pathValue.startsWith('https://')) {
      return pathValue;
    }
    final baseUri = Uri.parse(baseUrl);
    return baseUri.resolve(pathValue).toString();
  }

  Future<_StationApiResponse?> _stationApiRequest({
    required String method,
    required String path,
    Map<String, String>? headers,
    dynamic body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final connection = await _ensureStationConnectionInfo();
    if (connection == null) return null;

    if (connection.callsign != null && ConnectionManager().isInitialized) {
      try {
        final result = await ConnectionManager().apiRequest(
          callsign: connection.callsign!,
          method: method,
          path: path,
          headers: headers,
          body: body,
          timeout: timeout,
          excludeTransports: {'station'},
        );
        if (result.statusCode != null || result.responseData != null) {
          return _StationApiResponse(
            statusCode: result.statusCode ?? 200,
            data: result.responseData,
          );
        }
      } catch (_) {
        // Fall back to HTTP below.
      }
    }

    final baseUrl = connection.baseUrl;
    if (baseUrl == null || baseUrl.isEmpty) return null;

    try {
      final uri = Uri.parse(_resolveStationUrl(baseUrl, path));
      final encodedBody = body == null
          ? null
          : (body is String || body is List<int> ? body : jsonEncode(body));

      http.Response response;
      switch (method.toUpperCase()) {
        case 'POST':
          response = await http
              .post(uri, headers: headers, body: encodedBody)
              .timeout(timeout);
          break;
        case 'PUT':
          response = await http
              .put(uri, headers: headers, body: encodedBody)
              .timeout(timeout);
          break;
        case 'DELETE':
          response = await http
              .delete(uri, headers: headers, body: encodedBody)
              .timeout(timeout);
          break;
        default:
          response = await http.get(uri, headers: headers).timeout(timeout);
      }

      final responseData = _isBinaryContentType(response.headers['content-type'])
          ? response.bodyBytes
          : response.body;
      return _StationApiResponse(
        statusCode: response.statusCode,
        data: responseData,
      );
    } catch (_) {
      return null;
    }
  }

  String _responseToString(dynamic data) {
    if (data == null) return '';
    if (data is String) return data;
    if (data is List<int>) {
      try {
        return utf8.decode(data);
      } catch (_) {
        return '';
      }
    }
    try {
      return jsonEncode(data);
    } catch (_) {
      return data.toString();
    }
  }

  bool _isBinaryContentType(String? contentType) {
    if (contentType == null || contentType.isEmpty) return false;
    final normalized = contentType.toLowerCase();
    return normalized.startsWith('image/') ||
        normalized.startsWith('audio/') ||
        normalized.startsWith('video/') ||
        normalized.startsWith('application/octet-stream') ||
        normalized.startsWith('application/pdf');
  }

  Future<io.Directory> _getMediaCacheDir() async {
    final baseDir = io.Directory(path.join(io.Directory.systemTemp.path, 'geogram_event_media'));
    if (!await baseDir.exists()) {
      await baseDir.create(recursive: true);
    }
    return baseDir;
  }

  Future<List<int>?> _fetchRemoteMediaBytes(String apiPath) async {
    final response = await _stationApiRequest(
      method: 'GET',
      path: apiPath,
      headers: {'Accept': '*/*'},
      timeout: const Duration(seconds: 30),
    );

    if (response == null || response.statusCode != 200) return null;

    final data = response.data;
    if (data is List<int>) {
      return data;
    }
    return null;
  }

  Future<String?> _getRemoteFilePath(_MediaFileEntry file) async {
    if (!file.isRemote) return file.path;

    final cached = _cachedRemoteFiles[file.path];
    if (cached != null) {
      final cachedFile = io.File(cached);
      if (await cachedFile.exists()) {
        return cached;
      }
    }

    if (_remoteFileFutures.containsKey(file.path)) {
      return _remoteFileFutures[file.path]!;
    }

    final future = () async {
      try {
        final bytes = await _fetchRemoteMediaBytes(file.path);
        if (bytes == null || bytes.isEmpty) return null;

        final cacheDir = await _getMediaCacheDir();
        final safeName = '${file.path.hashCode}_${file.name}';
        final targetPath = path.join(cacheDir.path, safeName);
        final targetFile = io.File(targetPath);
        await targetFile.writeAsBytes(bytes, flush: true);
        _cachedRemoteFiles[file.path] = targetPath;
        return targetPath;
      } catch (_) {
        return null;
      }
    }();

    _remoteFileFutures[file.path] = future;
    final resolved = await future;
    _remoteFileFutures.remove(file.path);
    return resolved;
  }

  Future<bool> _postStationMediaAction(String callsign, String action) async {
    final response = await _stationApiRequest(
      method: 'POST',
      path: '/api/events/${widget.event.id}/media/$callsign/$action',
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'moderator_callsign': widget.currentCallsign,
        'moderator_npub': widget.currentUserNpub,
      }),
      timeout: const Duration(seconds: 15),
    );

    if (response == null) {
      _showMessage(_i18n.t('station_required_for_media'), isError: true);
      return false;
    }

    if (response.statusCode != 200) {
      _showMessage('${_i18n.t('error')}: ${response.statusCode}', isError: true);
      return false;
    }

    return true;
  }

  Future<void> _addContribution() async {
    if (_isUploading || !_supportsMedia || kIsWeb) return;
    if (_useStation) {
      await _addStationContribution();
    } else {
      await _addLocalContribution();
    }
  }

  Future<void> _addLocalContribution() async {
    final mediaRoot = _mediaRoot;
    if (mediaRoot == null) return;

    final callsign = _sanitizeCallsign(widget.currentCallsign ?? '');
    if (callsign.isEmpty) {
      _showMessage(_i18n.t('no_active_callsign'), isError: true);
      return;
    }

    if (_isPublic) {
      final banned = _banned.isNotEmpty ? _banned : await _readList(_bannedFilePath);
      if (banned.contains(callsign)) {
        _showMessage(_i18n.t('contribution_upload_blocked'), isError: true);
        return;
      }
    }

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
      dialogTitle: _i18n.t('add_contribution'),
    );

    if (result == null || result.files.isEmpty) return;

    setState(() => _isUploading = true);
    try {
      final contributorDir = io.Directory('$mediaRoot/$callsign');
      await contributorDir.create(recursive: true);

      var nextIndex = await _nextMediaIndex(contributorDir);
      int copiedCount = 0;

      for (final file in result.files) {
        final sourcePath = file.path;
        if (sourcePath == null || sourcePath.isEmpty) continue;
        final ext = _normalizeExtension(file.name);
        final targetName = 'media$nextIndex.$ext';
        nextIndex++;

        final sourceFile = io.File(sourcePath);
        if (!await sourceFile.exists()) continue;
        await sourceFile.copy('${contributorDir.path}/$targetName');
        copiedCount++;
      }

      if (copiedCount > 0) {
        _showMessage(_i18n.t('files_uploaded', params: [copiedCount.toString()]));
      }

      await _loadContributions();
    } catch (e) {
      _showMessage('${_i18n.t('error')}: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  Future<void> _addStationContribution() async {
    if (await _ensureStationConnectionInfo() == null) {
      _showMessage(_i18n.t('station_required_for_media'), isError: true);
      return;
    }

    final callsign = _sanitizeCallsign(widget.currentCallsign ?? '');
    if (callsign.isEmpty) {
      _showMessage(_i18n.t('no_active_callsign'), isError: true);
      return;
    }

    if (_banned.contains(callsign)) {
      _showMessage(_i18n.t('contribution_upload_blocked'), isError: true);
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
      dialogTitle: _i18n.t('add_contribution'),
    );

    if (result == null || result.files.isEmpty) return;

    setState(() => _isUploading = true);
    try {
      int uploaded = 0;

      for (final file in result.files) {
        final sourcePath = file.path;
        if (sourcePath == null || sourcePath.isEmpty) continue;
        final sourceFile = io.File(sourcePath);
        if (!await sourceFile.exists()) continue;

        final ext = _normalizeExtension(file.name);
        final uploadName = 'upload.$ext';

        final bytes = await sourceFile.readAsBytes();
        final response = await _stationApiRequest(
          method: 'POST',
          path: '/api/events/${widget.event.id}/media/$callsign/files/$uploadName',
          headers: {
            'Content-Type': 'application/octet-stream',
            'Content-Transfer-Encoding': 'base64',
          },
          body: base64Encode(bytes),
          timeout: const Duration(seconds: 30),
        );

        if (response == null) {
          _showMessage(_i18n.t('station_required_for_media'), isError: true);
          break;
        }

        if (response.statusCode == 201 || response.statusCode == 200) {
          uploaded++;
        } else if (response.statusCode == 403) {
          _showMessage(_i18n.t('contribution_upload_blocked'), isError: true);
          break;
        } else {
          _showMessage('${_i18n.t('error')}: ${response.statusCode}', isError: true);
        }
      }

      if (uploaded > 0) {
        _showMessage(_i18n.t('files_uploaded', params: [uploaded.toString()]));
      }

      await _loadContributions();
    } catch (e) {
      _showMessage('${_i18n.t('error')}: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  Future<int> _nextMediaIndex(io.Directory contributorDir) async {
    int maxIndex = 0;
    if (await contributorDir.exists()) {
      await for (final entry in contributorDir.list()) {
        if (entry is! io.File) continue;
        final name = path.basename(entry.path);
        final match = RegExp(r'^media(\d+)\.', caseSensitive: false).firstMatch(name);
        if (match == null) continue;
        final parsed = int.tryParse(match.group(1) ?? '');
        if (parsed != null && parsed > maxIndex) {
          maxIndex = parsed;
        }
      }
    }
    return maxIndex + 1;
  }

  String _normalizeExtension(String filename) {
    var ext = path.extension(filename).toLowerCase();
    if (ext.startsWith('.')) ext = ext.substring(1);
    if (ext.isEmpty) ext = 'bin';
    if (ext.length > 8) {
      ext = ext.substring(0, 8);
    }
    return ext;
  }

  String _sanitizeCallsign(String callsign) {
    return callsign
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }

  bool _isImageFile(String filePath) {
    final ext = path.extension(filePath).toLowerCase();
    return ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'].contains(ext);
  }

  bool _isVideoFile(String filePath) {
    final ext = path.extension(filePath).toLowerCase();
    return ['.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm'].contains(ext);
  }

  bool _isMediaFile(String filePath) {
    return _isImageFile(filePath) || _isVideoFile(filePath);
  }

  Future<void> _approveContributor(String callsign) async {
    if (!_isPublic) return;
    if (_useStation) {
      final ok = await _postStationMediaAction(callsign, 'approve');
      if (ok) {
        _showMessage(_i18n.t('contributor_approved'));
        await _loadContributions();
      }
      return;
    }

    final approved = Set<String>.from(_approved)..add(callsign);
    final banned = Set<String>.from(_banned)..remove(callsign);
    await _writeList(_approvedFilePath, approved);
    await _writeList(_bannedFilePath, banned);
    _showMessage(_i18n.t('contributor_approved'));
    await _loadContributions();
  }

  Future<void> _suspendContributor(String callsign) async {
    if (!_isPublic) return;
    if (_useStation) {
      final ok = await _postStationMediaAction(callsign, 'suspend');
      if (ok) {
        _showMessage(_i18n.t('contributor_suspended'));
        await _loadContributions();
      }
      return;
    }

    final approved = Set<String>.from(_approved)..remove(callsign);
    await _writeList(_approvedFilePath, approved);
    _showMessage(_i18n.t('contributor_suspended'));
    await _loadContributions();
  }

  Future<void> _banContributor(String callsign) async {
    if (!_isPublic) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('ban_user')),
        content: Text(_i18n.t('ban_user_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(_i18n.t('ban')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    if (_useStation) {
      final ok = await _postStationMediaAction(callsign, 'ban');
      if (ok) {
        _showMessage(_i18n.t('contributor_banned'));
        await _loadContributions();
      }
      return;
    }

    final approved = Set<String>.from(_approved)..remove(callsign);
    final banned = Set<String>.from(_banned)..add(callsign);
    await _writeList(_approvedFilePath, approved);
    await _writeList(_bannedFilePath, banned);

    final mediaRoot = _mediaRoot;
    if (mediaRoot != null) {
      final dir = io.Directory('$mediaRoot/$callsign');
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }

    _showMessage(_i18n.t('contributor_banned'));
    await _loadContributions();
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
      ),
    );
  }

  Future<void> _openImageViewer(
    BuildContext context,
    List<_MediaFileEntry> imageFiles,
    _MediaFileEntry selected,
  ) async {
    if (imageFiles.isEmpty) return;

    final hasRemote = imageFiles.any((file) => file.isRemote);
    bool dialogShown = false;
    if (hasRemote && mounted) {
      dialogShown = true;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    try {
      final resolvedPaths = <String, String>{};
      for (final file in imageFiles) {
        if (file.isRemote) {
          final localPath = await _getRemoteFilePath(file);
          if (localPath != null) {
            resolvedPaths[file.path] = localPath;
          }
        } else {
          resolvedPaths[file.path] = file.path;
        }
      }

      final imagePaths = imageFiles
          .map((file) => resolvedPaths[file.path])
          .whereType<String>()
          .toList();

      if (imagePaths.isEmpty) {
        _showMessage(_i18n.t('error'), isError: true);
        return;
      }

      final selectedPath = resolvedPaths[selected.path];
      final initialIndex = selectedPath != null ? imagePaths.indexOf(selectedPath) : 0;
      if (dialogShown && mounted) {
        Navigator.of(context).pop();
        dialogShown = false;
      }
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => PhotoViewerPage(
            imagePaths: imagePaths,
            initialIndex: initialIndex >= 0 ? initialIndex : 0,
          ),
        ),
      );
    } finally {
      if (dialogShown && mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _openFile(_MediaFileEntry file) async {
    if (kIsWeb) return;
    final pathValue = file.isRemote ? await _getRemoteFilePath(file) : file.path;
    if (pathValue == null || pathValue.isEmpty) return;
    final uri = Uri.file(pathValue);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Widget _buildMediaThumbnail(_MediaFileEntry file, ThemeData theme) {
    if (!file.isRemote) {
      final imageProvider = file_helper.getFileImageProvider(file.path);
      if (imageProvider != null) {
        return Image(
          image: imageProvider,
          width: 80,
          height: 80,
          fit: BoxFit.cover,
        );
      }
      return Container(
        width: 80,
        height: 80,
        color: theme.colorScheme.surfaceVariant,
        child: const Icon(Icons.image),
      );
    }

    return FutureBuilder<String?>(
      future: _getRemoteFilePath(file),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            width: 80,
            height: 80,
            color: theme.colorScheme.surfaceVariant,
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        final localPath = snapshot.data;
        if (localPath != null && localPath.isNotEmpty) {
          final imageProvider = file_helper.getFileImageProvider(localPath);
          if (imageProvider != null) {
            return Image(
              image: imageProvider,
              width: 80,
              height: 80,
              fit: BoxFit.cover,
            );
          }
        }

        return Container(
          width: 80,
          height: 80,
          color: theme.colorScheme.surfaceVariant,
          child: const Icon(Icons.image),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaRoot = _mediaRoot;
    if (!_supportsMedia || kIsWeb || (!_useStation && mediaRoot == null)) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final visibleContributors = _isPublic
        ? _contributors.where((entry) => entry.isApproved && !entry.isBanned).toList()
        : _contributors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              _i18n.t('community_media'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _isUploading ? null : _addContribution,
              icon: const Icon(Icons.add_photo_alternate),
              label: Text(_i18n.t('add_contribution')),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _i18n.t('community_media_info'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        if (!_isLoading && _stationError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              _stationError!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else if (!_isLoading && visibleContributors.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              _i18n.t(_isPublic ? 'no_approved_contributions' : 'no_contributions_yet'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          ...visibleContributors.map((entry) => _buildContributorCard(
                entry,
                theme,
                showStatus: false,
                showActions: false,
              )),
        if (_canModerate) ...[
          const SizedBox(height: 16),
          Text(
            _i18n.t('review_contributions'),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          if (_contributors.isEmpty)
            Text(
              _i18n.t('no_contributions_yet'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            ..._contributors.map((entry) => _buildContributorCard(
                  entry,
                  theme,
                  showStatus: true,
                  showActions: true,
                )),
        ],
      ],
    );
  }

  Widget _buildContributorCard(
    _ContributorMediaEntry entry,
    ThemeData theme, {
    required bool showStatus,
    required bool showActions,
  }) {
    final status = entry.isBanned
        ? _i18n.t('banned')
        : entry.isApproved
            ? _i18n.t('approved')
            : _i18n.t('pending');

    final statusColor = entry.isBanned
        ? theme.colorScheme.error
        : entry.isApproved
            ? Colors.green
            : theme.colorScheme.secondary;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  entry.callsign,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (showStatus) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      status,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: statusColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                if (showActions) ...[
                  if (!entry.isApproved && !entry.isBanned)
                    TextButton(
                      onPressed: () => _approveContributor(entry.callsign),
                      child: Text(_i18n.t('approve')),
                    ),
                  if (entry.isApproved)
                    TextButton(
                      onPressed: () => _suspendContributor(entry.callsign),
                      child: Text(_i18n.t('suspend')),
                    ),
                  TextButton(
                    onPressed: () => _banContributor(entry.callsign),
                    style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                    child: Text(_i18n.t('ban')),
                  ),
                ],
              ],
            ),
            if (entry.imageFiles.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: entry.imageFiles.map((file) {
                  return InkWell(
                    onTap: () => _openImageViewer(context, entry.imageFiles, file),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _buildMediaThumbnail(file, theme),
                    ),
                  );
                }).toList(),
              ),
            ],
            if (entry.otherFiles.isNotEmpty) ...[
              const SizedBox(height: 8),
              ...entry.otherFiles.map((file) {
                final name = file.name;
                return InkWell(
                  onTap: () => _openFile(file),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.insert_drive_file, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            name,
                            style: theme.textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ],
          ],
        ),
      ),
    );
  }
}
