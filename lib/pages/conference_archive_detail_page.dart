library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../bot/services/speech_to_text_service.dart';
import '../models/chat_message.dart';
import '../models/conference_archive_entry.dart';
import '../services/conference_archive_service.dart';
import '../services/file_launcher_service.dart';
import '../services/meeting_transcription_service.dart';
import '../widgets/message_list_widget.dart';
import '../widgets/video_player_widget.dart';
import '../work/utils/voicememo_transcription_service.dart';

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
  bool _exportingNdf = false;
  String? _error;

  ConferenceArchiveAsset? _playingRecording;
  String? _playingRecordingPath;
  bool _isFullscreen = false;

  // Transcription state
  StreamSubscription? _progressSub;
  TranscriptionProgress? _transcriptionProgress;
  String? _transcribingRecordingName;

  ConferenceArchiveEntry get _currentEntry => _entry ?? widget.entry;

  @override
  void initState() {
    super.initState();
    _progressSub = _transcriptionService.progressStream.listen((progress) {
      if (mounted) {
        setState(() => _transcriptionProgress = progress);
      }
    });
    _loadArchive();
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
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
      setState(() {
        _entry = refreshed;
        _messages = messages;
        _loading = false;
      });
      if (refreshed.recordings.isNotEmpty && _playingRecording == null) {
        _playRecording(refreshed.recordings.first);
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

  void _stopPlayback() {
    setState(() {
      _playingRecording = null;
      _playingRecordingPath = null;
      _isFullscreen = false;
    });
  }

  Future<void> _transcribeRecording(ConferenceArchiveAsset recording) async {
    if (_transcriptionService.isBusy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A transcription is already in progress')),
      );
      return;
    }

    setState(() {
      _transcribingRecordingName = recording.name;
    });

    try {
      // Export MP4 to temp path
      final mp4Path = await _archiveService.exportArchiveFileToTemporaryPath(
        _currentEntry,
        recording.relativePath,
      );
      if (mp4Path == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to export recording')),
        );
        setState(() => _transcribingRecordingName = null);
        return;
      }

      final result = await _transcriptionService.transcribeRecording(
        mp4Path: mp4Path,
        recordingName: recording.name,
      );

      if (!mounted) return;

      if (result.cancelled) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Transcription cancelled')),
        );
      } else if (result.success && result.text != null) {
        // Write transcript to archive
        await _archiveService.writeTranscriptForRecording(
          _currentEntry,
          recording.name,
          result.text!,
        );
        // Refresh archive to pick up new transcript
        await _loadArchive();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Transcription complete')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Transcription failed: ${result.error ?? "Unknown error"}')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Transcription error: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _transcribingRecordingName = null);
      }
    }
  }

  Future<void> _cancelTranscription() async {
    await _transcriptionService.cancel();
  }

  Future<void> _exportAsNdf() async {
    if (_exportingNdf) return;
    setState(() => _exportingNdf = true);

    try {
      final tempDir = await getTemporaryDirectory();
      final sanitizedName = _currentEntry.roomName
          .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
          .toLowerCase();
      final date = _currentEntry.startedAt.toLocal();
      final dateStr =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      final outputPath = p.join(
        tempDir.path,
        '${sanitizedName}_$dateStr.meeting.ndf',
      );

      await _archiveService.exportAsNdf(_currentEntry, outputPath);

      if (!mounted) return;

      final opened = await _fileLauncher.openFile(outputPath);
      if (!mounted) return;
      if (!opened) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('NDF exported to: $outputPath')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _exportingNdf = false);
      }
    }
  }

  bool _hasTranscript(String recordingName) {
    final baseName = p.basenameWithoutExtension(recordingName);
    return _currentEntry.voiceTranscripts.any(
      (t) => p.basenameWithoutExtension(t.name) == baseName,
    );
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
                    'Transcribing: ${_transcribingRecordingName ?? ""}',
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

  Widget _buildSummaryTab(ThemeData theme) {
    final entry = _currentEntry;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_transcribingRecordingName != null)
          _buildTranscriptionProgressIndicator(theme),
        if (_playingRecording != null && _playingRecordingPath != null)
          Card(
            clipBehavior: Clip.antiAlias,
            margin: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                  child: Row(
                    children: [
                      Icon(Icons.play_arrow,
                          size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _playingRecording!.name,
                          style: theme.textTheme.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Stop playback',
                        onPressed: _stopPlayback,
                      ),
                    ],
                  ),
                ),
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: VideoPlayerWidget(
                    videoPath: _playingRecordingPath!,
                    autoPlay: true,
                    onFullscreenToggle: () {
                      setState(() => _isFullscreen = !_isFullscreen);
                    },
                  ),
                ),
              ],
            ),
          ),
        if (entry.recordings.isNotEmpty)
          _RecordingSection(
            recordings: entry.recordings,
            openingDisabled: _openingAsset,
            onPlayRecording: _playRecording,
            onTranscribeRecording: _transcribeRecording,
            hasTranscript: _hasTranscript,
            isTranscribing: _transcriptionService.isBusy,
            transcribingName: _transcribingRecordingName,
            sttSupported: SpeechToTextService.isSupported,
          ),
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
            _InfoRow(label: 'Name', value: entry.roomName),
            _InfoRow(
              label: 'Role',
              value: entry.hostedByMe ? 'Hosted by you' : 'Participated',
            ),
            _InfoRow(
              label: 'Host',
              value: entry.hostCallsign.isEmpty
                  ? 'Unknown'
                  : entry.hostCallsign,
            ),
            _InfoRow(label: 'Started', value: _formatDateTime(entry.startedAt)),
            _InfoRow(
              label: 'Ended',
              value: entry.endedAt == null
                  ? 'In progress'
                  : _formatDateTime(entry.endedAt!),
            ),
            _InfoRow(label: 'Mode', value: entry.signalingMode.toUpperCase()),
          ],
        ),
        _InfoCard(
          title: 'Participants',
          children: [
            _InfoRow(
              label: 'Participants',
              value: entry.participants.isEmpty
                  ? 'None'
                  : entry.participants.join(', '),
            ),
            _InfoRow(
              label: 'Speakers',
              value: entry.speakers.isEmpty
                  ? 'None'
                  : entry.speakers.join(', '),
            ),
            _InfoRow(
              label: 'Screen Share',
              value: entry.activeScreenSharer ?? 'None',
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
      const Tab(text: 'Summary'),
      if (hasChat) const Tab(text: 'Chat'),
      if (hasFiles) const Tab(text: 'Files'),
      if (hasTranscripts) const Tab(text: 'Transcripts'),
    ];
    final tabViews = <Widget>[
      _buildSummaryTab(theme),
      if (hasChat) _buildChatTab(theme),
      if (hasFiles) _buildFilesTab(theme),
      if (hasTranscripts) _buildTranscriptTab(theme),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(entry.roomName),
        actions: [
          if (entry.recordings.isNotEmpty)
            IconButton(
              icon: _exportingNdf
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.archive_outlined),
              tooltip: 'Export as NDF',
              onPressed: _exportingNdf ? null : _exportAsNdf,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh archive',
            onPressed: _loadArchive,
          ),
        ],
      ),
      body: tabs.length == 1
          ? _buildSummaryTab(theme)
          : DefaultTabController(
              key: ValueKey(tabs.length),
              length: tabs.length,
              child: Column(
                children: [
                  TabBar(tabs: tabs),
                  Expanded(child: TabBarView(children: tabViews)),
                ],
              ),
            ),
    );
  }
}

class _RecordingSection extends StatelessWidget {
  final List<ConferenceArchiveAsset> recordings;
  final bool openingDisabled;
  final Future<void> Function(ConferenceArchiveAsset) onPlayRecording;
  final Future<void> Function(ConferenceArchiveAsset) onTranscribeRecording;
  final bool Function(String) hasTranscript;
  final bool isTranscribing;
  final String? transcribingName;
  final bool sttSupported;

  const _RecordingSection({
    required this.recordings,
    required this.openingDisabled,
    required this.onPlayRecording,
    required this.onTranscribeRecording,
    required this.hasTranscript,
    required this.isTranscribing,
    required this.transcribingName,
    required this.sttSupported,
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
                Icon(Icons.fiber_manual_record,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Recordings',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...recordings.map((asset) {
              final transcribed = hasTranscript(asset.name);
              final currentlyTranscribing =
                  isTranscribing && transcribingName == asset.name;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.videocam,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                title: Text(asset.name),
                subtitle: Text(_formatAssetSubtitle(asset)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (sttSupported) ...[
                      if (currentlyTranscribing)
                        const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else if (transcribed)
                        const Icon(Icons.check_circle, color: Colors.green, size: 20)
                      else
                        IconButton(
                          icon: const Icon(Icons.transcribe),
                          tooltip: 'Transcribe recording',
                          onPressed: isTranscribing
                              ? null
                              : () => onTranscribeRecording(asset),
                        ),
                      const SizedBox(width: 4),
                    ],
                    IconButton(
                      icon: const Icon(Icons.play_arrow),
                      tooltip: 'Play recording',
                      onPressed: openingDisabled
                          ? null
                          : () => onPlayRecording(asset),
                    ),
                  ],
                ),
                onTap: openingDisabled ? null : () => onPlayRecording(asset),
              );
            }),
          ],
        ),
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
  final bool isRecording;

  const _AssetSection({
    required this.title,
    required this.icon,
    required this.assets,
    required this.emptyLabel,
    required this.openingDisabled,
    required this.onOpenAsset,
    this.isRecording = false,
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
                    isRecording
                        ? Icons.videocam
                        : Icons.insert_drive_file,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(asset.name),
                  subtitle: Text(_formatAssetSubtitle(asset)),
                  trailing: IconButton(
                    icon: Icon(
                        isRecording ? Icons.play_arrow : Icons.open_in_new),
                    tooltip: isRecording ? 'Play recording' : 'Open file',
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
