/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/audio_service.dart';
import '../../services/i18n_service.dart';
import '../../services/log_service.dart';
import '../models/ndf_document.dart';
import '../models/voicememo_content.dart';
import '../services/ndf_service.dart';
import '../utils/voicememo_transcription_service.dart';
import '../widgets/voicememo/voicememo_clip_card_widget.dart';
import '../widgets/voicememo/voicememo_recorder_widget.dart';

/// Voice memo editor page
class VoiceMemoEditorPage extends StatefulWidget {
  final String filePath;
  final String? title;

  const VoiceMemoEditorPage({
    super.key,
    required this.filePath,
    this.title,
  });

  @override
  State<VoiceMemoEditorPage> createState() => _VoiceMemoEditorPageState();
}

class _VoiceMemoEditorPageState extends State<VoiceMemoEditorPage> {
  final I18nService _i18n = I18nService();
  final NdfService _ndfService = NdfService();
  final AudioService _audioService = AudioService();
  final VoiceMemoTranscriptionService _transcriptionService =
      VoiceMemoTranscriptionService();
  final FocusNode _focusNode = FocusNode();

  NdfDocument? _metadata;
  VoiceMemoContent? _content;
  List<VoiceMemoClip> _clips = [];
  bool _isLoading = true;
  bool _hasChanges = false;
  bool _isRecording = false;
  String? _error;
  Set<String> _expandedClips = {};
  String? _playingClipId;
  String? _transcribingClipId; // Track which clip is being transcribed
  TranscriptionProgress? _transcriptionProgress; // Detailed progress info
  StreamSubscription<TranscriptionProgress>? _progressSubscription;
  StreamSubscription<TranscriptionCompletedEvent>? _completionSubscription;

  @override
  void initState() {
    super.initState();
    _audioService.initialize();
    _transcriptionService.initialize();
    _loadDocument();

    // Listen to transcription progress updates
    _progressSubscription = _transcriptionService.progressStream.listen((progress) {
      if (mounted) {
        setState(() {
          _transcriptionProgress = progress;
        });
      }
    });

    // Listen to transcription completion events (for background transcriptions)
    _completionSubscription = _transcriptionService.completionStream.listen((event) {
      if (!mounted) return;
      // Only handle events for this document
      if (event.filePath != widget.filePath) return;

      if (event.success && event.updatedClip != null) {
        // Update the clip in our list
        final index = _clips.indexWhere((c) => c.id == event.clipId);
        if (index != -1) {
          setState(() {
            _clips[index] = event.updatedClip!;
            _transcribingClipId = null;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_i18n.t('work_voicememo_transcription_complete'))),
          );
        }
      } else {
        setState(() {
          _transcribingClipId = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(event.error ?? _i18n.t('work_voicememo_transcription_failed')),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    });

    // Check if there's already a transcription running for this file
    _checkExistingTranscription();
  }

  /// Check if there's a transcription in progress for this file
  void _checkExistingTranscription() {
    if (_transcriptionService.isBusy &&
        _transcriptionService.currentFilePath == widget.filePath) {
      setState(() {
        _transcribingClipId = _transcriptionService.currentClipId;
        _transcriptionProgress = _transcriptionService.currentProgress;
        // Expand the clip so user can see the progress
        if (_transcribingClipId != null) {
          _expandedClips.add(_transcribingClipId!);
        }
      });
    }
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    _completionSubscription?.cancel();
    _focusNode.dispose();
    _audioService.stop();
    super.dispose();
  }

  Future<void> _loadDocument() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final metadata = await _ndfService.readMetadata(widget.filePath);
      if (metadata == null) {
        throw Exception('Could not read document metadata');
      }

      final content = await _ndfService.readVoiceMemoContent(widget.filePath);
      if (content == null) {
        throw Exception('Could not read voice memo content');
      }

      final clips = await _ndfService.readVoiceMemoClips(widget.filePath, content.clips);

      setState(() {
        _metadata = metadata;
        _content = content;
        _clips = clips;
        _isLoading = false;
      });
    } catch (e) {
      LogService().log('VoiceMemoEditorPage: Error loading document: $e');
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _save() async {
    if (_content == null || _metadata == null) return;

    try {
      _metadata!.touch();
      _content!.touch();

      await _ndfService.saveVoiceMemo(widget.filePath, _content!, _clips);
      await _ndfService.updateMetadata(widget.filePath, _metadata!);

      setState(() {
        _hasChanges = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('document_saved'))),
        );
      }
    } catch (e) {
      LogService().log('VoiceMemoEditorPage: Error saving document: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving: $e')),
        );
      }
    }
  }

  void _startRecording() {
    setState(() {
      _isRecording = true;
    });
  }

  void _onRecordingComplete(String filePath, int durationSeconds) async {
    setState(() {
      _isRecording = false;
    });

    // Read the recorded audio file
    try {
      final file = File(filePath);
      final audioBytes = await file.readAsBytes();

      // Show dialog to get clip details
      final clipTitle = await _showClipDetailsDialog();
      if (clipTitle == null) {
        // User cancelled, delete the temp file
        await file.delete();
        return;
      }

      // Determine audio extension from the recorded file
      final ext = filePath.split('.').last; // wav on Android, ogg on Linux
      // Create the clip - audioFile must match what saveClipAudio saves
      final clipId = 'clip-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
      final clip = VoiceMemoClip(
        id: clipId,
        title: clipTitle.title,
        description: clipTitle.description,
        recordedAt: DateTime.now(),
        finishedAt: DateTime.now(),
        durationMs: durationSeconds * 1000,
        audioFile: 'audio/$clipId.$ext', // Must match saveClipAudio path
      );

      // Save audio to archive
      await _ndfService.saveClipAudio(widget.filePath, clip.id, audioBytes, extension: ext);

      // Save clip metadata to archive
      await _ndfService.saveVoiceMemoClip(widget.filePath, clip);

      // Delete temp file
      await file.delete();

      // Update content and save
      _content?.addClip(clip.id);
      if (_content != null) {
        await _ndfService.saveVoiceMemo(widget.filePath, _content!, [clip]);
      }

      setState(() {
        _clips.add(clip);
        _hasChanges = false; // Already saved
      });
    } catch (e) {
      LogService().log('VoiceMemoEditorPage: Error saving recorded clip: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving recording: $e')),
        );
      }
    }
  }

  void _onRecordingCancel() {
    setState(() {
      _isRecording = false;
    });
  }

  /// Compute the next sequential clip number based on existing clip titles.
  int _nextClipNumber() {
    final pattern = RegExp(r'^Clip\s+(\d+)$', caseSensitive: false);
    int maxN = 0;
    for (final clip in _clips) {
      final match = pattern.firstMatch(clip.title);
      if (match != null) {
        final n = int.tryParse(match.group(1)!) ?? 0;
        if (n > maxN) maxN = n;
      }
    }
    return maxN + 1;
  }

  Future<({String title, String? description})?> _showClipDetailsDialog() async {
    final defaultTitle = 'Clip ${_nextClipNumber()}';
    final titleController = TextEditingController(text: defaultTitle);
    final descController = TextEditingController();

    // Select all text so user can easily replace it
    titleController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: defaultTitle.length,
    );

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_voicememo_record')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: InputDecoration(
                labelText: _i18n.t('work_voicememo_clip_title'),
                border: const OutlineInputBorder(),
              ),
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              inputFormatters: [_UpperCaseFirstLetterFormatter()],
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: descController,
              decoration: InputDecoration(
                labelText: _i18n.t('work_voicememo_clip_description'),
                border: const OutlineInputBorder(),
              ),
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              // Warn user that cancelling will lose the recording
              final discard = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(_i18n.t('work_voicememo_discard_clip')),
                  content: Text(_i18n.t('work_voicememo_discard_clip_confirm')),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(_i18n.t('work_voicememo_keep_recording')),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(ctx).colorScheme.error,
                      ),
                      child: Text(_i18n.t('discard')),
                    ),
                  ],
                ),
              );
              if (discard == true && context.mounted) {
                Navigator.pop(context, false);
              }
            },
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('save')),
          ),
        ],
      ),
    );

    if (result == true && titleController.text.trim().isNotEmpty) {
      return (
        title: titleController.text.trim(),
        description: descController.text.trim().isNotEmpty
            ? descController.text.trim()
            : null,
      );
    }
    return null;
  }

  void _editClip(VoiceMemoClip clip) async {
    final titleController = TextEditingController(text: clip.title);
    final descController = TextEditingController(text: clip.description ?? '');

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_voicememo_edit_clip')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: InputDecoration(
                labelText: _i18n.t('work_voicememo_clip_title'),
                border: const OutlineInputBorder(),
              ),
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: descController,
              decoration: InputDecoration(
                labelText: _i18n.t('work_voicememo_clip_description'),
                border: const OutlineInputBorder(),
              ),
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('save')),
          ),
        ],
      ),
    );

    if (result == true && titleController.text.trim().isNotEmpty) {
      setState(() {
        clip.title = titleController.text.trim();
        clip.description = descController.text.trim().isNotEmpty
            ? descController.text.trim()
            : null;
        _hasChanges = true;
      });
    }
  }

  void _deleteClip(VoiceMemoClip clip) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_voicememo_delete_clip')),
        content: Text(_i18n.t('work_voicememo_delete_clip_confirm').replaceAll('{name}', clip.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      // Stop playback if this clip is playing
      if (_playingClipId == clip.id) {
        await _audioService.stop();
        _playingClipId = null;
      }

      setState(() {
        _clips.removeWhere((c) => c.id == clip.id);
        _content?.removeClip(clip.id);
        _expandedClips.remove(clip.id);
        _hasChanges = true;
      });

      // Delete clip file and audio from archive
      try {
        await _ndfService.deleteVoiceMemoClip(widget.filePath, clip.id, clip.audioFile);
        await _ndfService.deleteClipSocialData(widget.filePath, clip.id);
      } catch (e) {
        LogService().log('VoiceMemoEditorPage: Error deleting clip file: $e');
      }
    }
  }

  void _toggleClipExpanded(String clipId) {
    setState(() {
      if (_expandedClips.contains(clipId)) {
        _expandedClips.remove(clipId);
      } else {
        _expandedClips.add(clipId);
      }
    });
  }

  Future<void> _playClip(VoiceMemoClip clip) async {
    try {
      // Stop any current playback
      if (_playingClipId != null) {
        await _audioService.stop();
        if (_playingClipId == clip.id) {
          setState(() {
            _playingClipId = null;
          });
          return;
        }
      }

      // Read audio from archive
      final audioBytes = await _ndfService.readClipAudio(widget.filePath, clip.audioFile);
      if (audioBytes == null) {
        throw Exception('Audio file not found');
      }

      // Write to temp file for playback (use original extension)
      final tempDir = Directory.systemTemp;
      final ext = clip.audioFile.split('.').last;
      final tempFile = File('${tempDir.path}/voicememo_${clip.id}.$ext');
      await tempFile.writeAsBytes(audioBytes);

      // Load and play
      await _audioService.load(tempFile.path);
      await _audioService.play();

      setState(() {
        _playingClipId = clip.id;
      });

      // Listen for playback completion
      _audioService.playingStream.listen((isPlaying) {
        if (!isPlaying && _playingClipId == clip.id) {
          if (mounted) {
            setState(() {
              _playingClipId = null;
            });
          }
          // Clean up temp file
          tempFile.delete().catchError((_) {});
        }
      });
    } catch (e) {
      LogService().log('VoiceMemoEditorPage: Error playing clip: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error playing audio: $e')),
        );
      }
    }
  }

  void _mergeClip(VoiceMemoClip sourceClip) async {
    // Get list of other clips to merge into
    final otherClips = _clips.where((c) => c.id != sourceClip.id).toList();
    if (otherClips.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('work_voicememo_no_clips'))),
      );
      return;
    }

    // Show dialog to select target clip
    final targetClip = await showDialog<VoiceMemoClip>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_voicememo_merge')),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: otherClips.length,
            itemBuilder: (context, index) {
              final clip = otherClips[index];
              return ListTile(
                leading: const Icon(Icons.mic),
                title: Text(clip.title),
                subtitle: Text(clip.durationFormatted),
                onTap: () => Navigator.pop(context, clip),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
        ],
      ),
    );

    if (targetClip == null) return;

    // Confirm merge
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_voicememo_merge')),
        content: Text(_i18n.t('work_voicememo_merge_confirm')
            .replaceAll('{source}', sourceClip.title)
            .replaceAll('{target}', targetClip.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('work_voicememo_merge')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // TODO: Implement actual audio merge using voicememo_merge_service
    // For now, just show a placeholder message
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_i18n.t('work_voicememo_merged'))),
    );
  }

  Future<void> _transcribeClip(VoiceMemoClip clip) async {
    // Check if already transcribing
    if (_transcribingClipId != null || _transcriptionService.isBusy) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('work_voicememo_transcription_busy')),
          action: SnackBarAction(
            label: _i18n.t('cancel'),
            onPressed: _cancelTranscription,
          ),
        ),
      );
      return;
    }

    // Check if whisper is available
    if (!await _transcriptionService.isSupported()) {
      _showWhisperNotInstalledDialog();
      return;
    }

    // Read audio from archive
    final audioBytes = await _ndfService.readClipAudio(
      widget.filePath,
      clip.audioFile,
    );
    if (audioBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('work_voicememo_audio_not_found'))),
      );
      return;
    }

    setState(() {
      _transcribingClipId = clip.id;
      _transcriptionProgress = null; // Reset progress
      // Expand the clip so user can see the progress
      _expandedClips.add(clip.id);
    });

    // Start background transcription - it will auto-save to NDF when complete
    // The completion handler will update the UI via the completionStream listener
    final started = _transcriptionService.transcribeInBackground(
      filePath: widget.filePath,
      clip: clip,
      audioBytes: audioBytes,
    );

    if (!started) {
      setState(() {
        _transcribingClipId = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('work_voicememo_transcription_failed'))),
      );
    }
    // Note: UI updates and saving are handled by the completionStream listener in initState
  }

  void _cancelTranscription() {
    _transcriptionService.cancel();
    setState(() {
      _transcribingClipId = null;
    });
  }

  Future<void> _deleteTranscriptionAndRetranscribe(VoiceMemoClip clip) async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_voicememo_retranscribe')),
        content: Text(_i18n.t('work_voicememo_delete_transcription')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_i18n.t('work_voicememo_retranscribe')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Delete transcription from clip
    final index = _clips.indexWhere((c) => c.id == clip.id);
    if (index == -1) return;

    final updatedClip = _clips[index].copyWith(
      transcription: null,
      clearTranscription: true,
    );

    // Save to archive
    await _ndfService.saveVoiceMemoClip(widget.filePath, updatedClip);

    setState(() {
      _clips[index] = updatedClip;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('work_voicememo_transcription_deleted'))),
      );
    }

    // Start new transcription
    await _transcribeClip(updatedClip);
  }

  void _showWhisperNotInstalledDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_voicememo_transcription_unavailable')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_i18n.t('work_voicememo_whisper_not_installed')),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  _transcriptionService.getInstallHelp(),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('ok')),
          ),
        ],
      ),
    );
  }

  List<VoiceMemoClip> _getSortedClips() {
    final clips = List<VoiceMemoClip>.from(_clips);
    final settings = _content?.settings ?? VoiceMemoSettings();

    switch (settings.defaultSort) {
      case VoiceMemoSortOrder.recordedAsc:
        clips.sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
        break;
      case VoiceMemoSortOrder.recordedDesc:
        clips.sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
        break;
      case VoiceMemoSortOrder.durationAsc:
        clips.sort((a, b) => a.durationMs.compareTo(b.durationMs));
        break;
      case VoiceMemoSortOrder.durationDesc:
        clips.sort((a, b) => b.durationMs.compareTo(a.durationMs));
        break;
    }

    return clips;
  }

  Future<bool> _onWillPop() async {
    if (!_hasChanges) return true;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('unsaved_changes')),
        content: Text(_i18n.t('unsaved_changes_message')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('discard')),
          ),
          FilledButton(
            onPressed: () async {
              await _save();
              if (mounted) Navigator.pop(context, true);
            },
            child: Text(_i18n.t('save')),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      final isCtrlPressed = HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed;

      if (isCtrlPressed && event.logicalKey == LogicalKeyboardKey.keyS) {
        _save();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: PopScope(
        canPop: !_hasChanges,
        onPopInvokedWithResult: (didPop, result) async {
          if (!didPop) {
            final shouldPop = await _onWillPop();
            if (shouldPop && mounted) {
              Navigator.of(context).pop();
            }
          }
        },
        child: Scaffold(
          appBar: AppBar(
            title: GestureDetector(
              onTap: _renameDocument,
              child: Text(_content?.title ?? widget.title ?? _i18n.t('work_voicememo')),
            ),
            actions: [
              if (_hasChanges)
                IconButton(
                  icon: const Icon(Icons.save),
                  onPressed: _save,
                  tooltip: _i18n.t('save'),
                ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: _handleMenuAction,
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'rename',
                    child: Row(
                      children: [
                        const Icon(Icons.edit_outlined),
                        const SizedBox(width: 8),
                        Text(_i18n.t('work_voicememo_rename')),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'settings',
                    child: Row(
                      children: [
                        const Icon(Icons.settings_outlined),
                        const SizedBox(width: 8),
                        Text(_i18n.t('work_voicememo_settings')),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: _buildBody(),
          floatingActionButton: _isRecording
              ? null
              : FloatingActionButton(
                  onPressed: _startRecording,
                  child: const Icon(Icons.mic),
                ),
        ),
      ),
    );
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'rename':
        _renameDocument();
        break;
      case 'settings':
        _showSettings();
        break;
    }
  }

  void _renameDocument() async {
    if (_content == null) return;

    final controller = TextEditingController(text: _content!.title);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_voicememo_rename')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: _i18n.t('title'),
            border: const OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(_i18n.t('save')),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && result != _content!.title) {
      setState(() {
        _content!.title = result;
        if (_metadata != null) {
          _metadata!.title = result;
        }
        _hasChanges = true;
      });
    }
  }

  void _showSettings() async {
    if (_content == null) return;

    final settings = _content!.settings;
    var allowComments = settings.allowComments;
    var allowRatings = settings.allowRatings;
    var ratingType = settings.ratingType;
    var defaultSort = settings.defaultSort;
    var showTranscriptions = settings.showTranscriptions;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(_i18n.t('work_voicememo_settings')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_i18n.t('work_voicememo_allow_comments')),
                    value: allowComments,
                    onChanged: (val) => setDialogState(() => allowComments = val),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_i18n.t('work_voicememo_allow_ratings')),
                    value: allowRatings,
                    onChanged: (val) => setDialogState(() => allowRatings = val),
                  ),
                  if (allowRatings) ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<RatingType>(
                      value: ratingType,
                      decoration: InputDecoration(
                        labelText: _i18n.t('work_voicememo_rating_type'),
                        border: const OutlineInputBorder(),
                      ),
                      items: RatingType.values.map((type) {
                        return DropdownMenuItem(
                          value: type,
                          child: Text(_getRatingTypeLabel(type)),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setDialogState(() => ratingType = val);
                        }
                      },
                    ),
                  ],
                  const SizedBox(height: 16),
                  DropdownButtonFormField<VoiceMemoSortOrder>(
                    value: defaultSort,
                    decoration: InputDecoration(
                      labelText: _i18n.t('sort_order'),
                      border: const OutlineInputBorder(),
                    ),
                    items: VoiceMemoSortOrder.values.map((order) {
                      return DropdownMenuItem(
                        value: order,
                        child: Text(_getSortOrderLabel(order)),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setDialogState(() => defaultSort = val);
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_i18n.t('work_voicememo_show_transcriptions')),
                    value: showTranscriptions,
                    onChanged: (val) => setDialogState(() => showTranscriptions = val),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(_i18n.t('cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(_i18n.t('save')),
              ),
            ],
          );
        },
      ),
    );

    if (result == true) {
      setState(() {
        _content!.settings = VoiceMemoSettings(
          allowComments: allowComments,
          allowRatings: allowRatings,
          ratingType: ratingType,
          defaultSort: defaultSort,
          showTranscriptions: showTranscriptions,
        );
        _hasChanges = true;
      });
    }
  }

  String _getRatingTypeLabel(RatingType type) {
    switch (type) {
      case RatingType.stars:
        return _i18n.t('work_voicememo_rating_stars');
      case RatingType.likeDislike:
        return _i18n.t('work_voicememo_rating_like_dislike');
      case RatingType.both:
        return _i18n.t('work_voicememo_rating_both');
    }
  }

  String _getSortOrderLabel(VoiceMemoSortOrder order) {
    switch (order) {
      case VoiceMemoSortOrder.recordedAsc:
        return _i18n.t('sort_oldest_first');
      case VoiceMemoSortOrder.recordedDesc:
        return _i18n.t('sort_newest_first');
      case VoiceMemoSortOrder.durationAsc:
        return _i18n.t('sort_shortest_first');
      case VoiceMemoSortOrder.durationDesc:
        return _i18n.t('sort_longest_first');
    }
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      final theme = Theme.of(context);
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(_i18n.t('error_loading_document')),
            const SizedBox(height: 8),
            Text(_error!, style: theme.textTheme.bodySmall),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _loadDocument,
              icon: const Icon(Icons.refresh),
              label: Text(_i18n.t('retry')),
            ),
          ],
        ),
      );
    }

    // Show recorder overlay if recording
    if (_isRecording) {
      return Stack(
        children: [
          _buildClipsList(),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: VoiceMemoRecorderWidget(
              onSend: _onRecordingComplete,
              onCancel: _onRecordingCancel,
            ),
          ),
        ],
      );
    }

    return _buildClipsList();
  }

  Widget _buildClipsList() {
    final sortedClips = _getSortedClips();

    if (sortedClips.isEmpty) {
      final theme = Theme.of(context);
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.mic_none_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(_i18n.t('work_voicememo_no_clips')),
            const SizedBox(height: 8),
            Text(
              _i18n.t('work_voicememo_add_first'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Summary header
        if (_content != null && sortedClips.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              _i18n.t('work_voicememo_total_duration')
                  .replaceAll('{count}', sortedClips.length.toString())
                  .replaceAll('{duration}', _content!.getTotalDurationFormatted(sortedClips)),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: sortedClips.length,
            itemBuilder: (context, index) {
              final clip = sortedClips[index];
              return VoiceMemoClipCardWidget(
                key: ValueKey(clip.id),
                clip: clip,
                isExpanded: _expandedClips.contains(clip.id),
                isPlaying: _playingClipId == clip.id,
                settings: _content?.settings ?? VoiceMemoSettings(),
                onToggleExpanded: () => _toggleClipExpanded(clip.id),
                onPlay: () => _playClip(clip),
                onEdit: () => _editClip(clip),
                onDelete: () => _deleteClip(clip),
                onMerge: () => _mergeClip(clip),
                onTranscribe: () => _transcribeClip(clip),
                isTranscribing: _transcribingClipId == clip.id,
                transcriptionProgress: _transcribingClipId == clip.id
                    ? _transcriptionProgress
                    : null,
                onCancelTranscription: _transcribingClipId == clip.id
                    ? _cancelTranscription
                    : null,
                onDeleteTranscription: clip.transcription != null
                    ? () => _deleteTranscriptionAndRetranscribe(clip)
                    : null,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Ensures the first letter of the input is always uppercase.
class _UpperCaseFirstLetterFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) return newValue;
    final first = newValue.text[0].toUpperCase();
    if (first == newValue.text[0]) return newValue;
    final newText = first + newValue.text.substring(1);
    return newValue.copyWith(text: newText);
  }
}
