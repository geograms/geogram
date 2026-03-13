library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../bot/services/speech_to_text_service.dart';
import '../models/chat_message.dart';
import '../models/conference_archive_entry.dart';
import '../services/conference_archive_service.dart';
import '../services/conference_service.dart';
import '../services/file_launcher_service.dart';
import '../services/meeting_transcription_service.dart';
import '../widgets/message_list_widget.dart';
import '../widgets/video_player_widget.dart';
import '../work/utils/voicememo_transcription_service.dart';
import 'conference_call_page.dart';

class ConferenceArchiveDetailPage extends StatefulWidget {
  final ConferenceArchiveEntry entry;

  const ConferenceArchiveDetailPage({super.key, required this.entry});

  @override
  State<ConferenceArchiveDetailPage> createState() =>
      _ConferenceArchiveDetailPageState();
}

class _ConferenceArchiveDetailPageState
    extends State<ConferenceArchiveDetailPage> {
  final _archiveService = ConferenceArchiveService();
  final _fileLauncher = FileLauncherService();
  final _transcriptionService = MeetingTranscriptionService();

  ConferenceArchiveEntry? _entry;
  List<ChatMessage> _messages = const <ChatMessage>[];
  bool _loading = true;
  bool _openingAsset = false;
  String? _error;

  ConferenceArchiveAsset? _playingRecording;
  String? _playingRecordingPath;
  bool _isFullscreen = false;
  final _playerKey = GlobalKey();

  // Probed recording duration (ffprobe — authoritative)
  Duration _totalRecordingDuration = Duration.zero;

  // Transcription state
  StreamSubscription? _progressSub;
  StreamSubscription? _completionSub;
  TranscriptionProgress? _transcriptionProgress;

  ConferenceArchiveEntry get _currentEntry => _entry ?? widget.entry;

  @override
  void initState() {
    super.initState();
    _progressSub = _transcriptionService.progressStream.listen((progress) {
      if (mounted) {
        setState(() => _transcriptionProgress = progress);
      }
    });
    _completionSub = _transcriptionService.completionStream.listen((event) {
      if (event.archiveRelativePath == _currentEntry.relativePath) {
        if (event.success) {
          _loadArchive();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Transcription complete')),
            );
          }
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Transcription failed: ${event.error}'),
            ),
          );
        }
      }
    });
    _loadArchive();
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _completionSub?.cancel();
    super.dispose();
  }

  Future<Duration?> _probeVideoDuration(String filePath) async {
    try {
      final result = await Process.run('ffprobe', [
        '-v', 'quiet',
        '-print_format', 'json',
        '-show_format',
        filePath,
      ]);
      if (result.exitCode != 0) return null;
      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final format = json['format'] as Map<String, dynamic>?;
      final durationStr = format?['duration'] as String?;
      if (durationStr == null) return null;
      final seconds = double.parse(durationStr);
      return Duration(milliseconds: (seconds * 1000).round());
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadArchive() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final refreshed = await _archiveService.refreshArchive(_currentEntry);
      final messages = await _archiveService.loadMessages(refreshed);
      if (!mounted) {
        return;
      }

      // Probe recording durations with ffprobe
      var probedTotal = Duration.zero;
      String? firstRecordingPath;
      for (final rec in refreshed.recordings) {
        final path = await _archiveService.exportArchiveFileToTemporaryPath(
          refreshed, rec.relativePath);
        if (path != null) {
          firstRecordingPath ??= path;
          final dur = await _probeVideoDuration(path);
          if (dur != null) probedTotal += dur;
        }
      }
      if (!mounted) return;

      setState(() {
        _entry = refreshed;
        _messages = messages;
        _totalRecordingDuration = probedTotal;
        _loading = false;
      });
      if (refreshed.recordings.isNotEmpty && _playingRecording == null) {
        // Reuse the already-extracted path for auto-play
        if (firstRecordingPath != null) {
          setState(() {
            _playingRecording = refreshed.recordings.first;
            _playingRecordingPath = firstRecordingPath;
          });
        } else {
          _playRecording(refreshed.recordings.first);
        }
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _openAsset(ConferenceArchiveAsset asset) async {
    if (_openingAsset) {
      return;
    }

    setState(() => _openingAsset = true);
    try {
      final path = await _archiveService.exportArchiveFileToTemporaryPath(
        _currentEntry,
        asset.relativePath,
      );
      if (!mounted) {
        return;
      }
      if (path == null) {
        throw StateError('Unable to export ${asset.name}');
      }
      final opened = await _fileLauncher.openFile(path);
      if (!mounted) {
        return;
      }
      if (!opened) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Unable to open ${asset.name}')));
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to open ${asset.name}: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _openingAsset = false);
      }
    }
  }

  Future<void> _playRecording(ConferenceArchiveAsset asset) async {
    if (_openingAsset) return;

    setState(() => _openingAsset = true);
    try {
      final path = await _archiveService.exportArchiveFileToTemporaryPath(
        _currentEntry,
        asset.relativePath,
      );
      if (!mounted) return;
      if (path == null) {
        throw StateError('Unable to export ${asset.name}');
      }
      setState(() {
        _playingRecording = asset;
        _playingRecordingPath = path;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to play ${asset.name}: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _openingAsset = false);
      }
    }
  }


  Future<void> _transcribeRecording(ConferenceArchiveAsset recording) async {
    if (_transcriptionService.isBusy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A transcription is already in progress')),
      );
      return;
    }

    final started = _transcriptionService.transcribeInBackground(
      entry: _currentEntry,
      recording: recording,
    );

    if (!started && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to start transcription')),
      );
    }
  }

  Future<void> _cancelTranscription() async {
    await _transcriptionService.cancel();
  }

  bool _hasTranscript(String recordingName) {
    final baseName = p.basenameWithoutExtension(recordingName);
    return _currentEntry.voiceTranscripts.any(
      (t) => p.basenameWithoutExtension(t.name) == baseName,
    );
  }

  Future<void> _downloadNdf() async {
    final entry = _currentEntry;
    final fileName = '${entry.roomName}.ndf';

    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save meeting archive',
      fileName: fileName,
    );
    if (savePath == null || !mounted) return;

    try {
      await _archiveService.exportAsNdf(entry, savePath);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Archive saved')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save: $e')),
      );
    }
  }

  Future<void> _deleteArchive() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete meeting'),
        content: Text(
          'Delete "${_currentEntry.roomName}" and all its recordings, '
          'chat, and files? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await _archiveService.deleteArchive(_currentEntry);
      if (!mounted) return;
      Navigator.of(context).pop(true); // true = was deleted
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete: $e')),
      );
    }
  }

  Future<void> _resumeMeeting() async {
    final entry = _currentEntry;
    final conferenceService = ConferenceService();
    if (conferenceService.isActive) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A meeting is already active')),
      );
      return;
    }

    try {
      await conferenceService.hostConference(
        roomName: entry.roomName,
        resumeFromArchive: entry,
      );
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ConferenceCallPage()),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to resume: $e')),
      );
    }
  }

  Future<void> _editName() async {
    final controller = TextEditingController(text: _currentEntry.roomName);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit meeting name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;
    if (result == _currentEntry.roomName) return;
    try {
      final updated = await _archiveService.updateArchive(
        _currentEntry,
        roomName: result,
      );
      if (!mounted) return;
      setState(() => _entry = updated);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to rename: $e')),
      );
    }
  }

  String _formatMeetingDuration(ConferenceArchiveEntry entry) {
    // 1. Sessions sum
    var sessionTotal = Duration.zero;
    for (final s in entry.sessions) {
      final end = s.endedAt ?? entry.updatedAt;
      sessionTotal += end.difference(s.startedAt);
    }

    // 2. Entry-level span
    final entryEnd = entry.endedAt ?? entry.updatedAt;
    final entrySpan = entryEnd.difference(entry.startedAt);

    // 3. Recording span: last recording modifiedAt minus meeting start
    var recordingSpan = Duration.zero;
    for (final r in entry.recordings) {
      if (r.modifiedAt != null) {
        final span = r.modifiedAt!.difference(entry.startedAt);
        if (span > recordingSpan) recordingSpan = span;
      }
    }

    // Use the longest (most reliable) duration
    var total = sessionTotal;
    if (entrySpan > total) total = entrySpan;
    if (recordingSpan > total) total = recordingSpan;
    // 4. Probed recording durations (ffprobe — authoritative)
    if (_totalRecordingDuration > total) total = _totalRecordingDuration;
    if (total.isNegative) total = Duration.zero;

    // Format with full words
    final hours = total.inHours;
    final minutes = total.inMinutes.remainder(60);
    final seconds = total.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours ${hours == 1 ? 'hour' : 'hours'} $minutes ${minutes == 1 ? 'minute' : 'minutes'}';
    } else if (minutes > 0) {
      return '$minutes ${minutes == 1 ? 'minute' : 'minutes'} $seconds ${seconds == 1 ? 'second' : 'seconds'}';
    }
    return '$seconds ${seconds == 1 ? 'second' : 'seconds'}';
  }

  String _formatParticipant(String callsign) {
    final nick = _currentEntry.participantNicknames[callsign.toUpperCase()];
    return nick != null ? '$nick ($callsign)' : callsign;
  }

  Future<void> _editTags() async {
    final controller = TextEditingController();
    final currentTags = List<String>.from(_currentEntry.tags);
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit tags'),
          content: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (currentTags.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: currentTags
                        .map(
                          (tag) => InputChip(
                            label: Text(tag),
                            onDeleted: () => setDialogState(
                              () => currentTags.remove(tag),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                if (currentTags.isNotEmpty) const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        decoration: const InputDecoration(
                          hintText: 'Add a tag',
                          isDense: true,
                        ),
                        onSubmitted: (value) {
                          final tag = value.trim().toLowerCase();
                          if (tag.isNotEmpty && !currentTags.contains(tag)) {
                            setDialogState(() => currentTags.add(tag));
                            controller.clear();
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.add),
                      onPressed: () {
                        final tag = controller.text.trim().toLowerCase();
                        if (tag.isNotEmpty && !currentTags.contains(tag)) {
                          setDialogState(() => currentTags.add(tag));
                          controller.clear();
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(currentTags),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    try {
      final updated = await _archiveService.updateTags(_currentEntry, result);
      if (!mounted) return;
      setState(() => _entry = updated);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to update tags: $e')));
    }
  }

  // ── Player & Playlist (YouTube-like layout) ────────────────────────

  /// Inline player — compact, constrained height, YouTube-like.
  Widget _buildPlayer(ThemeData theme) {
    if (_playingRecordingPath == null) {
      return const SizedBox.shrink();
    }

    return Container(
      color: Colors.black,
      constraints: const BoxConstraints(maxHeight: 320),
      child: Center(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: VideoPlayerWidget(
            key: _playerKey,
            videoPath: _playingRecordingPath!,
            autoPlay: true,
            onFullscreenToggle: () {
              setState(() => _isFullscreen = !_isFullscreen);
            },
          ),
        ),
      ),
    );
  }

  /// YouTube playlist-style recording list — compact items with a
  /// highlighted "now playing" indicator.
  Widget _buildPlaylist(ThemeData theme) {
    final entry = _currentEntry;
    if (entry.recordings.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'Recordings (${entry.recordings.length})',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Flexible(child: ListView(
          shrinkWrap: true,
          children: entry.recordings.asMap().entries.map((mapEntry) {
          final index = mapEntry.key;
          final asset = mapEntry.value;
          final isPlaying = _playingRecording?.relativePath == asset.relativePath;
          final transcribed = _hasTranscript(asset.name);
          final currentlyTranscribing = _transcriptionService.isBusy &&
              _transcriptionService.currentRecordingName == asset.name;

          return Container(
            color: isPlaying
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                : null,
            child: InkWell(
              onTap: _openingAsset ? null : () => _playRecording(asset),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    // Index or now-playing indicator
                    SizedBox(
                      width: 32,
                      child: Center(
                        child: isPlaying
                            ? Icon(Icons.equalizer,
                                size: 18, color: theme.colorScheme.primary)
                            : Text(
                                '${index + 1}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                      ),
                    ),
                    // Recording icon
                    Icon(
                      Icons.videocam,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    // Name + subtitle
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            asset.name,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: isPlaying ? FontWeight.w600 : null,
                              color: isPlaying
                                  ? theme.colorScheme.primary
                                  : null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            _formatAssetSubtitle(asset),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Transcription status
                    if (SpeechToTextService.isSupported) ...[
                      if (currentlyTranscribing)
                        const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else if (transcribed)
                        const Icon(Icons.check_circle, color: Colors.green, size: 18)
                      else
                        IconButton(
                          icon: const Icon(Icons.transcribe, size: 18),
                          tooltip: 'Transcribe',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: _transcriptionService.isBusy
                              ? null
                              : () => _transcribeRecording(asset),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          );
        }).toList(),
        )),
        const Divider(height: 1),
      ],
    );
  }

  Widget _buildTranscriptionProgressIndicator(ThemeData theme) {
    final progress = _transcriptionProgress;
    if (progress == null || progress.state == TranscriptionState.idle) {
      return const SizedBox.shrink();
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.transcribe, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Transcribing: ${_transcriptionService.currentRecordingName ?? ""}',
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (progress.state != TranscriptionState.cancelling)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Cancel transcription',
                    onPressed: _cancelTranscription,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: progress.progress > 0 ? progress.progress : null,
            ),
            const SizedBox(height: 4),
            Text(
              progress.message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Session info ───────────────────────────────────────────────────

  Widget _buildSessionsInfo(ThemeData theme) {
    final sessions = _currentEntry.sessions;
    if (sessions.length <= 1) return const SizedBox.shrink();

    return _InfoCard(
      title: 'Sessions (${sessions.length})',
      children: [
        ...sessions.asMap().entries.map((mapEntry) {
          final i = mapEntry.key;
          final s = mapEntry.value;
          final label = 'Session ${i + 1}';
          final value = s.endedAt != null
              ? '${_formatDateTime(s.startedAt)} - ${_formatDateTime(s.endedAt!)}'
              : '${_formatDateTime(s.startedAt)} (active)';
          return _InfoRow(label: label, value: value);
        }),
      ],
    );
  }

  // ── Tab content ────────────────────────────────────────────────────

  Widget _buildInfoTab(ThemeData theme) {
    final entry = _currentEntry;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_transcriptionService.isBusy)
          _buildTranscriptionProgressIndicator(theme),
        _InfoCard(
          title: 'Tags',
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ...entry.tags.map(
                  (tag) => Chip(
                    label: Text(tag),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                ActionChip(
                  avatar: const Icon(Icons.edit, size: 16),
                  label: Text(
                    entry.tags.isEmpty ? 'Add tags' : 'Edit',
                  ),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  onPressed: _editTags,
                ),
              ],
            ),
          ],
        ),
        _InfoCard(
          title: 'Meeting',
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(
                      'Name',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      entry.roomName,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit, size: 16),
                    tooltip: 'Edit name',
                    onPressed: _editName,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            _InfoRow(
              label: 'Role',
              value: entry.hostedByMe ? 'Hosted by you' : 'Participated',
            ),
            _InfoRow(
              label: 'Host',
              value: entry.hostCallsign.isEmpty
                  ? 'Unknown'
                  : _formatParticipant(entry.hostCallsign),
            ),
            _InfoRow(label: 'Date', value: _formatDateTime(entry.startedAt)),
            _InfoRow(label: 'Duration', value: _formatMeetingDuration(entry)),
          ],
        ),
        _buildSessionsInfo(theme),
        _InfoCard(
          title: 'Participants',
          children: [
            _InfoRow(
              label: 'Participants',
              value: entry.participants.isEmpty
                  ? 'None'
                  : entry.participants
                      .map(_formatParticipant)
                      .join(', '),
            ),
            _InfoRow(
              label: 'Speakers',
              value: entry.speakers.isEmpty
                  ? 'None'
                  : entry.speakers
                      .map(_formatParticipant)
                      .join(', '),
            ),
          ],
        ),
        _InfoCard(
          title: 'Archive',
          children: [
            _InfoRow(label: 'Messages', value: '${entry.messageCount}'),
            _InfoRow(label: 'Files', value: '${entry.fileCount}'),
            _InfoRow(label: 'Recordings', value: '${entry.recordingCount}'),
            _InfoRow(label: 'Transcripts', value: '${entry.voiceTranscripts.length}'),
            _InfoRow(label: 'Archive', value: entry.relativePath),
            if (entry.stationMeetUrl != null &&
                entry.stationMeetUrl!.isNotEmpty)
              _InfoRow(label: 'Meeting URL', value: entry.stationMeetUrl!),
            if (entry.meetUrls.isNotEmpty)
              _InfoRow(label: 'URLs', value: entry.meetUrls.join('\n')),
          ],
        ),
      ],
    );
  }

  Widget _buildChatTab(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.error,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return MessageListWidget(messages: _messages, isGroupChat: true);
  }

  Widget _buildFilesTab(ThemeData theme) {
    final entry = _currentEntry;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _AssetSection(
          title: 'Files',
          icon: Icons.attach_file,
          assets: entry.files,
          emptyLabel: 'No files shared in this meeting',
          openingDisabled: _openingAsset,
          onOpenAsset: _openAsset,
        ),
      ],
    );
  }

  Widget _buildTranscriptTab(ThemeData theme) {
    final entry = _currentEntry;
    if (entry.voiceTranscripts.isEmpty) {
      return Center(
        child: Text(
          'No transcripts available',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: entry.voiceTranscripts.length,
      itemBuilder: (context, index) {
        final transcript = entry.voiceTranscripts[index];
        return _TranscriptCard(
          transcript: transcript,
          archiveService: _archiveService,
          entry: entry,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = _currentEntry;

    if (_isFullscreen && _playingRecordingPath != null) {
      return Scaffold(
        body: VideoPlayerWidget(
          key: _playerKey,
          videoPath: _playingRecordingPath!,
          autoPlay: true,
          onFullscreenToggle: () {
            setState(() => _isFullscreen = !_isFullscreen);
          },
        ),
      );
    }

    final hasChat = _messages.isNotEmpty;
    final hasFiles = entry.files.isNotEmpty;
    final hasTranscripts = entry.voiceTranscripts.isNotEmpty;

    final tabs = <Tab>[
      const Tab(text: 'Info'),
      if (hasChat) const Tab(text: 'Chat'),
      if (hasFiles) const Tab(text: 'Files'),
      if (hasTranscripts) const Tab(text: 'Transcripts'),
    ];
    final tabViews = <Widget>[
      _buildInfoTab(theme),
      if (hasChat) _buildChatTab(theme),
      if (hasFiles) _buildFilesTab(theme),
      if (hasTranscripts) _buildTranscriptTab(theme),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(entry.roomName),
        actions: [
          // Resume / restart meeting
          if (entry.endedAt != null)
            IconButton(
              icon: const Icon(Icons.play_circle_outline),
              tooltip: 'Resume meeting',
              onPressed: _resumeMeeting,
            ),
          // Download NDF
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Download NDF',
            onPressed: _downloadNdf,
          ),
          // Delete archive
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete meeting',
            onPressed: _deleteArchive,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isLandscape = constraints.maxWidth > constraints.maxHeight;

          if (isLandscape && _playingRecordingPath != null) {
            // Right column tabs — everything except Chat
            final rightTabs = <Tab>[
              const Tab(text: 'Info'),
              if (hasFiles) const Tab(text: 'Files'),
              if (hasTranscripts) const Tab(text: 'Transcripts'),
            ];
            final rightViews = <Widget>[
              _buildInfoTab(theme),
              if (hasFiles) _buildFilesTab(theme),
              if (hasTranscripts) _buildTranscriptTab(theme),
            ];

            final rightContent = rightTabs.length == 1
                ? _buildInfoTab(theme)
                : DefaultTabController(
                    key: ValueKey('right-${rightTabs.length}'),
                    length: rightTabs.length,
                    child: Column(
                      children: [
                        TabBar(tabs: rightTabs),
                        Expanded(child: TabBarView(children: rightViews)),
                      ],
                    ),
                  );

            // Landscape: 2/3 video+playlist+chat | 1/3 details
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left column — player, playlist, chat
                SizedBox(
                  width: (constraints.maxWidth * 2 / 3).roundToDouble(),
                  child: Column(
                    children: [
                      _buildPlayer(theme),
                      _buildPlaylist(theme),
                      if (hasChat) Expanded(child: _buildChatTab(theme)),
                    ],
                  ),
                ),
                // Right column — info/files/transcripts
                Expanded(child: rightContent),
              ],
            );
          }

          // Portrait (or no video playing): vertical stack with all tabs
          final tabContent = tabs.length == 1
              ? _buildInfoTab(theme)
              : DefaultTabController(
                  key: ValueKey(tabs.length),
                  length: tabs.length,
                  child: Column(
                    children: [
                      TabBar(tabs: tabs),
                      Expanded(child: TabBarView(children: tabViews)),
                    ],
                  ),
                );

          return Column(
            children: [
              _buildPlayer(theme),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: _buildPlaylist(theme),
              ),
              Expanded(child: tabContent),
            ],
          );
        },
      ),
    );
  }
}

class _TranscriptCard extends StatefulWidget {
  final ConferenceArchiveAsset transcript;
  final ConferenceArchiveService archiveService;
  final ConferenceArchiveEntry entry;

  const _TranscriptCard({
    required this.transcript,
    required this.archiveService,
    required this.entry,
  });

  @override
  State<_TranscriptCard> createState() => _TranscriptCardState();
}

class _TranscriptCardState extends State<_TranscriptCard> {
  String? _text;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadTranscript();
  }

  Future<void> _loadTranscript() async {
    try {
      final text = await widget.archiveService.readTranscriptForRecording(
        widget.entry,
        widget.transcript.name,
      );
      if (mounted) {
        setState(() {
          _text = text;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _text = 'Error loading transcript: $e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.transcribe,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.transcript.name,
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_text != null)
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: 'Copy to clipboard',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _text!));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Transcript copied to clipboard')),
                      );
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_text != null)
              Container(
                constraints: const BoxConstraints(maxHeight: 400),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _text!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      height: 1.6,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AssetSection extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<ConferenceArchiveAsset> assets;
  final String emptyLabel;
  final bool openingDisabled;
  final Future<void> Function(ConferenceArchiveAsset asset) onOpenAsset;

  const _AssetSection({
    required this.title,
    required this.icon,
    required this.assets,
    required this.emptyLabel,
    required this.openingDisabled,
    required this.onOpenAsset,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (assets.isEmpty)
              Text(
                emptyLabel,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              ...assets.map(
                (asset) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.insert_drive_file,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(asset.name),
                  subtitle: Text(_formatAssetSubtitle(asset)),
                  trailing: IconButton(
                    icon: const Icon(Icons.open_in_new),
                    tooltip: 'Open file',
                    onPressed: openingDisabled
                        ? null
                        : () => onOpenAsset(asset),
                  ),
                  onTap: openingDisabled ? null : () => onOpenAsset(asset),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _InfoCard({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

String _formatAssetSubtitle(ConferenceArchiveAsset asset) {
  final parts = <String>[];
  if (asset.size != null) {
    parts.add(_formatFileSize(asset.size!));
  }
  if (asset.modifiedAt != null) {
    parts.add(_formatDateTime(asset.modifiedAt!));
  }
  return parts.isEmpty ? asset.relativePath : parts.join(' • ');
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  final year = local.year.toString().padLeft(4, '0');
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  final second = local.second.toString().padLeft(2, '0');
  return '$year-$month-$day $hour:$minute:$second';
}

String _formatFileSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
