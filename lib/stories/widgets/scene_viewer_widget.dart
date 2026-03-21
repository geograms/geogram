/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/story.dart';
import '../models/story_scene.dart';
import '../models/story_element.dart';
import '../models/story_trigger.dart';
import '../services/quiz_state_store.dart';
import '../services/stories_storage_service.dart';
import 'story_element_widget.dart';

/// Widget that renders a scene with its background, elements, and handles timing
class SceneViewerWidget extends StatefulWidget {
  final StoryScene scene;
  final Story story;
  final StoriesStorageService storage;
  final Function(StoryTrigger) onTrigger;
  final bool isEditing;
  final QuizStateStore? quizStore;

  const SceneViewerWidget({
    super.key,
    required this.scene,
    required this.story,
    required this.storage,
    required this.onTrigger,
    this.isEditing = false,
    this.quizStore,
  });

  @override
  State<SceneViewerWidget> createState() => _SceneViewerWidgetState();
}

class _SceneViewerWidgetState extends State<SceneViewerWidget> {
  String? _backgroundImagePath;
  Player? _videoPlayer;
  VideoController? _videoController;
  bool _showBackground = false;
  final Map<String, bool> _visibleElements = {};
  Timer? _timingTimer;
  int _elapsedMs = 0;
  final Map<String, QuizState> _quizStates = {};
  final Set<String> _dismissedQuizzes = {};

  @override
  void initState() {
    super.initState();
    _loadQuizStates();
    _loadBackground();
    _startTiming();
  }

  @override
  void didUpdateWidget(SceneViewerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scene.id != widget.scene.id) {
      // Scene changed, reset everything
      _backgroundImagePath = null;
      _disposeVideoPlayer();
      _showBackground = false;
      _visibleElements.clear();
      _elapsedMs = 0;
      _quizStates.clear();
      _dismissedQuizzes.clear();
      _loadQuizStates();
      _loadBackground();
      _startTiming();
    }
  }

  @override
  void dispose() {
    _timingTimer?.cancel();
    _disposeVideoPlayer();
    super.dispose();
  }

  void _disposeVideoPlayer() {
    _videoPlayer?.dispose();
    _videoPlayer = null;
    _videoController = null;
  }

  Future<void> _loadBackground() async {
    final bg = widget.scene.background;

    // Load video if present (video takes priority)
    if (bg.hasVideo) {
      final path = await widget.storage.extractMedia(
        widget.story,
        bg.videoAsset!,
      );
      if (mounted && path != null) {
        await _initVideoPlayer(path);
      }
    }
    // Otherwise load image
    else if (bg.hasImage) {
      final path = await widget.storage.extractMedia(
        widget.story,
        bg.asset!,
      );
      if (mounted && path != null) {
        setState(() => _backgroundImagePath = path);
      }
    }
  }

  Future<void> _initVideoPlayer(String videoPath) async {
    _disposeVideoPlayer();

    _videoPlayer = Player();
    _videoController = VideoController(_videoPlayer!);

    // Video plays once (no loop)
    await _videoPlayer!.open(Media(videoPath));
    await _videoPlayer!.play();
    if (mounted) setState(() {});
  }

  void _startTiming() {
    _timingTimer?.cancel();
    _elapsedMs = 0;

    // Check initial visibility
    _updateVisibility();

    // Start timer for timed elements
    _timingTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      _elapsedMs += 50;
      _updateVisibility();

      // Stop when all elements are visible
      if (_allElementsVisible()) {
        timer.cancel();
      }
    });
  }

  void _updateVisibility() {
    setState(() {
      // Background visibility
      _showBackground = _elapsedMs >= widget.scene.background.appearAt;

      // Element visibility
      for (final element in widget.scene.elements) {
        _visibleElements[element.id] = _elapsedMs >= element.appearAt;
      }
    });
  }

  bool _allElementsVisible() {
    if (!_showBackground && widget.scene.background.appearAt > 0) return false;

    for (final element in widget.scene.elements) {
      if (!(_visibleElements[element.id] ?? false)) return false;
    }
    return true;
  }

  void _handleElementTap(StoryElement element) {
    final trigger = widget.scene.getTriggerForElement(element.id);
    if (trigger != null) {
      widget.onTrigger(trigger);
    }
  }

  void _handleTouchAreaTap(TouchArea area) {
    final triggers = widget.scene.touchAreaTriggers;
    for (final trigger in triggers) {
      if (trigger.touchArea == area) {
        widget.onTrigger(trigger);
        break;
      }
    }
  }

  void _loadQuizStates() {
    if (widget.quizStore == null) return;
    for (final element in widget.scene.elements) {
      if (element.type == ElementType.quiz) {
        final state = widget.quizStore!.getState(
          widget.story.id,
          element.id,
        );
        _quizStates[element.id] = state;
        // Already-solved quizzes are dismissed immediately
        if (state.solved) {
          _dismissedQuizzes.add(element.id);
        }
      }
    }
  }

  void _handleQuizAnswer(StoryElement element, String answer) {
    if (widget.quizStore == null) return;
    final current = _quizStates[element.id] ?? const QuizState();
    if (current.solved || current.isLocked) return;

    final correct = answer.trim().toLowerCase() ==
        (element.quizAnswer ?? '').trim().toLowerCase();

    final newState = correct
        ? QuizState(attemptsUsed: current.attemptsUsed, solved: true)
        : QuizState(attemptsUsed: current.attemptsUsed + 1, solved: false);

    widget.quizStore!.saveState(widget.story.id, element.id, newState);
    setState(() {
      _quizStates[element.id] = newState;
    });

    // Auto-dismiss the quiz widget 5 seconds after correct answer
    if (correct) {
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted) {
          setState(() {
            _dismissedQuizzes.add(element.id);
          });
        }
      });
    }
  }

  /// Whether all quizzes are solved (for blur animation target)
  bool get _allQuizzesSolved {
    for (final element in widget.scene.elements) {
      if (element.type == ElementType.quiz) {
        final state = _quizStates[element.id] ?? const QuizState();
        if (!state.solved) return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            // Background
            _buildBackground(constraints),

            // Touch areas (invisible but tappable)
            ..._buildTouchAreas(constraints),

            // Elements
            ..._buildElements(constraints),
          ],
        );
      },
    );
  }

  Widget _buildBackground(BoxConstraints constraints) {
    final bg = widget.scene.background;
    final placeholderColor = _parseColor(bg.placeholder);

    if (!_showBackground) {
      return Container(
        width: constraints.maxWidth,
        height: constraints.maxHeight,
        color: placeholderColor,
      );
    }

    // Always use cover to ensure consistent element positioning across orientations
    const fit = BoxFit.cover;

    Widget mediaWidget;

    // Video background (takes priority over image)
    if (bg.hasVideo && _videoController != null) {
      mediaWidget = Video(
        controller: _videoController!,
        controls: NoVideoControls,
        fit: fit,
        width: constraints.maxWidth,
        height: constraints.maxHeight,
      );
    }
    // Image background
    else if (_backgroundImagePath != null) {
      mediaWidget = Image.file(
        File(_backgroundImagePath!),
        width: constraints.maxWidth,
        height: constraints.maxHeight,
        fit: fit,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    } else {
      mediaWidget = const SizedBox.shrink();
    }

    // Check if we need blur for quiz elements
    final hasQuiz = widget.scene.elements.any((e) => e.type == ElementType.quiz);
    final targetSigma = (hasQuiz && !_allQuizzesSolved) ? 20.0 : 0.0;

    Widget backgroundWidget = AnimatedOpacity(
      opacity: _showBackground ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Container(
        width: constraints.maxWidth,
        height: constraints.maxHeight,
        color: placeholderColor,
        child: mediaWidget,
      ),
    );

    if (hasQuiz) {
      backgroundWidget = TweenAnimationBuilder<double>(
        tween: Tween(begin: targetSigma, end: targetSigma),
        duration: const Duration(milliseconds: 800),
        builder: (context, sigma, child) {
          if (sigma <= 0.1) return child!;
          return ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: child,
          );
        },
        child: backgroundWidget,
      );
    }

    return backgroundWidget;
  }

  List<Widget> _buildTouchAreas(BoxConstraints constraints) {
    final triggers = widget.scene.touchAreaTriggers;
    if (triggers.isEmpty) return [];

    return triggers.map((trigger) {
      if (trigger.touchArea == null) return const SizedBox.shrink();

      final rect = _getTouchAreaRect(trigger.touchArea!, constraints);
      return Positioned(
        left: rect.left,
        top: rect.top,
        width: rect.width,
        height: rect.height,
        child: GestureDetector(
          onTap: () => _handleTouchAreaTap(trigger.touchArea!),
          behavior: HitTestBehavior.opaque,
          child: Container(
            color: Colors.transparent,
          ),
        ),
      );
    }).toList();
  }

  Rect _getTouchAreaRect(TouchArea area, BoxConstraints constraints) {
    final w = constraints.maxWidth;
    final h = constraints.maxHeight;

    switch (area) {
      case TouchArea.leftHalf:
        return Rect.fromLTWH(0, 0, w / 2, h);
      case TouchArea.rightHalf:
        return Rect.fromLTWH(w / 2, 0, w / 2, h);
      case TouchArea.topHalf:
        return Rect.fromLTWH(0, 0, w, h / 2);
      case TouchArea.bottomHalf:
        return Rect.fromLTWH(0, h / 2, w, h / 2);
      case TouchArea.topLeft:
        return Rect.fromLTWH(0, 0, w / 2, h / 2);
      case TouchArea.topRight:
        return Rect.fromLTWH(w / 2, 0, w / 2, h / 2);
      case TouchArea.bottomLeft:
        return Rect.fromLTWH(0, h / 2, w / 2, h / 2);
      case TouchArea.bottomRight:
        return Rect.fromLTWH(w / 2, h / 2, w / 2, h / 2);
      case TouchArea.center:
        return Rect.fromLTWH(w / 4, h / 4, w / 2, h / 2);
    }
  }

  List<Widget> _buildElements(BoxConstraints constraints) {
    final w = constraints.maxWidth;
    final h = constraints.maxHeight;

    return widget.scene.elements.where((element) {
      // Hide dismissed quiz elements (solved + 5s elapsed)
      if (element.type == ElementType.quiz && _dismissedQuizzes.contains(element.id)) {
        return false;
      }
      return true;
    }).map((element) {
      final isVisible = _visibleElements[element.id] ?? false;

      final position = element.position;
      final isTextOrTitle = element.type == ElementType.text ||
          element.type == ElementType.title ||
          element.type == ElementType.quiz;

      final child = StoryElementWidget(
        element: element,
        story: widget.story,
        storage: widget.storage,
        constraints: constraints,
        onTap: isVisible ? () => _handleElementTap(element) : null,
        isEditing: widget.isEditing,
        quizState: element.type == ElementType.quiz
            ? (_quizStates[element.id] ?? const QuizState())
            : null,
        onQuizAnswer: element.type == ElementType.quiz
            ? (answer) => _handleQuizAnswer(element, answer)
            : null,
      );

      if (isTextOrTitle) {
        // For text/title elements, use anchor-based centering with intrinsic sizing
        // Position at anchor point, then translate to center horizontally
        final (anchorX, anchorY) = position.anchorPercent;
        final leftPx = (anchorX / 100) * w + (position.offsetX / 100) * w;
        final topPx = (anchorY / 100) * h + (position.offsetY / 100) * h;

        return Positioned(
          left: leftPx,
          top: topPx,
          child: FractionalTranslation(
            translation: const Offset(-0.5, 0), // Center horizontally on anchor
            child: AnimatedOpacity(
              opacity: isVisible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: child,
            ),
          ),
        );
      } else {
        // For buttons, use percentage-based sizing
        final (left, top) = position.calculatePosition();
        final leftPx = (left / 100) * w;
        final topPx = (top / 100) * h;
        final widthPx = position.widthPercent > 0 ? (position.widthPercent / 100) * w : null;
        final heightPx = position.heightPercent != null ? (position.heightPercent! / 100) * h : null;

        return Positioned(
          left: leftPx,
          top: topPx,
          width: widthPx,
          height: heightPx,
          child: AnimatedOpacity(
            opacity: isVisible ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 300),
            child: child,
          ),
        );
      }
    }).toList();
  }

  Color _parseColor(String colorString) {
    if (colorString.startsWith('#')) {
      final hex = colorString.substring(1);
      if (hex.length == 6) {
        return Color(int.parse('FF$hex', radix: 16));
      } else if (hex.length == 8) {
        return Color(int.parse(hex, radix: 16));
      }
    } else if (colorString.startsWith('rgba')) {
      // Parse rgba(r, g, b, a) format
      final match = RegExp(r'rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)')
          .firstMatch(colorString);
      if (match != null) {
        return Color.fromRGBO(
          int.parse(match.group(1)!),
          int.parse(match.group(2)!),
          int.parse(match.group(3)!),
          double.parse(match.group(4)!),
        );
      }
    }
    return Colors.black;
  }
}
