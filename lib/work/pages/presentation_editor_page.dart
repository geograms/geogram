/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' show Platform;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show Uint8List, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/i18n_service.dart';
import '../../services/log_service.dart';
import '../models/ndf_document.dart';
import '../models/presentation_content.dart';
import '../services/ndf_service.dart';
import '../widgets/presentation/slide_canvas_widget.dart';
import '../widgets/presentation/slide_thumbnail_widget.dart';

/// Presentation editor page
class PresentationEditorPage extends StatefulWidget {
  final String filePath;
  final String? title;

  const PresentationEditorPage({
    super.key,
    required this.filePath,
    this.title,
  });

  @override
  State<PresentationEditorPage> createState() => _PresentationEditorPageState();
}

class _PresentationEditorPageState extends State<PresentationEditorPage> {
  final I18nService _i18n = I18nService();
  final NdfService _ndfService = NdfService();
  final ImagePicker _imagePicker = ImagePicker();

  NdfDocument? _metadata;
  PresentationContent? _content;
  Map<String, PresentationSlide> _slides = {};
  int _currentSlideIndex = 0;
  String? _selectedElementId;
  bool _isLoading = true;
  bool _hasChanges = false;
  String? _error;
  bool _isPresenting = false;

  // Current template for new slides
  SlideTemplate _currentTemplate = SlideTemplate.templates.first;

  // Notes controller
  final TextEditingController _notesController = TextEditingController();
  final FocusNode _notesFocusNode = FocusNode();

  // Inline text editing
  bool _isInlineEditing = false;
  final TextEditingController _textEditController = TextEditingController();
  final FocusNode _textEditFocusNode = FocusNode();
  List<SlideTextSpan>? _originalSpansBeforeEdit;

  @override
  void initState() {
    super.initState();
    _loadDocument();
  }

  @override
  void dispose() {
    _notesController.dispose();
    _notesFocusNode.dispose();
    _textEditController.dispose();
    _textEditFocusNode.dispose();
    super.dispose();
  }

  PresentationSlide? get _currentSlide {
    if (_content == null || _content!.slides.isEmpty) return null;
    if (_currentSlideIndex >= _content!.slides.length) return null;
    final slideId = _content!.slides[_currentSlideIndex];
    return _slides[slideId];
  }

  Future<void> _loadDocument() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Load metadata
      final metadata = await _ndfService.readMetadata(widget.filePath);
      if (metadata == null) {
        throw Exception('Could not read document metadata');
      }

      // Load content
      final content = await _ndfService.readPresentationContent(widget.filePath);
      if (content == null) {
        throw Exception('Could not read presentation content');
      }

      // Load all slides
      final slides = <String, PresentationSlide>{};
      for (final slideId in content.slides) {
        final slide = await _ndfService.readSlide(widget.filePath, slideId);
        if (slide != null) {
          slides[slideId] = slide;
        } else {
          // Create default slide if not found
          slides[slideId] = PresentationSlide.blank(
            id: slideId,
            index: slides.length,
          );
        }
      }

      // Ensure we have at least one slide
      if (slides.isEmpty) {
        const defaultSlideId = 'slide-001';
        slides[defaultSlideId] = PresentationSlide.title(
          id: defaultSlideId,
          index: 0,
          title: metadata.title,
        );
        content.slides.add(defaultSlideId);
      }

      setState(() {
        _metadata = metadata;
        _content = content;
        _slides = slides;
        _currentSlideIndex = 0;
        _isLoading = false;
      });

      // Update notes controller
      _updateNotesController();
    } catch (e) {
      LogService().log('PresentationEditorPage: Error loading document: $e');
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _updateNotesController() {
    final slide = _currentSlide;
    _notesController.text = slide?.notes ?? '';
  }

  Future<void> _save() async {
    if (_content == null || _metadata == null) return;

    // Commit any inline editing in progress
    if (_isInlineEditing) {
      _commitInlineEdit();
    }

    try {
      // Save notes from controller to current slide
      final slide = _currentSlide;
      if (slide != null && _notesController.text != slide.notes) {
        slide.notes = _notesController.text;
      }

      // Update metadata modified time
      _metadata!.touch();

      // Save all slides
      await _ndfService.savePresentation(widget.filePath, _content!, _slides);

      // Update metadata
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
      LogService().log('PresentationEditorPage: Error saving document: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving: $e')),
        );
      }
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    final isCtrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;

    if (_isPresenting) {
      // Presentation mode navigation
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowRight:
        case LogicalKeyboardKey.arrowDown:
        case LogicalKeyboardKey.space:
        case LogicalKeyboardKey.pageDown:
          _nextSlide();
        case LogicalKeyboardKey.arrowLeft:
        case LogicalKeyboardKey.arrowUp:
        case LogicalKeyboardKey.pageUp:
          _previousSlide();
        case LogicalKeyboardKey.escape:
          _exitPresentMode();
        case LogicalKeyboardKey.home:
          _goToSlide(0);
        case LogicalKeyboardKey.end:
          _goToSlide((_content?.slides.length ?? 1) - 1);
      }
    } else if (_isInlineEditing) {
      // Inline editing mode shortcuts
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _cancelInlineEdit();
      } else if (isCtrl && event.logicalKey == LogicalKeyboardKey.enter) {
        _commitInlineEdit();
      } else if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyB) {
        _toggleInlineFormatting('bold');
      } else if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyI) {
        _toggleInlineFormatting('italic');
      } else if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyU) {
        _toggleInlineFormatting('underline');
      }
    } else {
      // Editor mode shortcuts
      if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyS) {
        _save();
      } else if (event.logicalKey == LogicalKeyboardKey.f5) {
        _enterPresentMode();
      }
    }
  }

  void _goToSlide(int index) {
    if (_content == null) return;
    if (index < 0 || index >= _content!.slides.length) return;

    // Commit any inline editing in progress
    if (_isInlineEditing) {
      _commitInlineEdit();
    }

    // Save current notes
    final currentSlide = _currentSlide;
    if (currentSlide != null && _notesController.text != currentSlide.notes) {
      currentSlide.notes = _notesController.text;
      _hasChanges = true;
    }

    setState(() {
      _currentSlideIndex = index;
      _selectedElementId = null;
    });

    _updateNotesController();
  }

  void _nextSlide() {
    if (_content == null) return;
    if (_currentSlideIndex < _content!.slides.length - 1) {
      _goToSlide(_currentSlideIndex + 1);
    }
  }

  void _previousSlide() {
    if (_currentSlideIndex > 0) {
      _goToSlide(_currentSlideIndex - 1);
    }
  }

  void _addSlide({SlideLayout layout = SlideLayout.blank}) {
    if (_content == null) return;

    final newId = 'slide-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final template = _currentTemplate;
    final colors = template.colors;

    PresentationSlide newSlide;
    switch (layout) {
      case SlideLayout.title:
        newSlide = PresentationSlide.title(
          id: newId,
          index: _content!.slides.length,
          title: _i18n.t('work_slide_title'),
          backgroundColor: colors.background,
        );
        // Apply template text color
        for (final element in newSlide.elements) {
          if (element.style != null) {
            newSlide.elements[newSlide.elements.indexOf(element)] = element.copyWith(
              style: element.style!.copyWith(color: colors.text),
            );
          }
        }
      case SlideLayout.titleContent:
        newSlide = PresentationSlide.titleContent(
          id: newId,
          index: _content!.slides.length,
          title: _i18n.t('work_slide_title'),
          content: _i18n.t('work_slide_content'),
          backgroundColor: colors.background,
        );
        // Apply template text color
        for (var i = 0; i < newSlide.elements.length; i++) {
          final element = newSlide.elements[i];
          if (element.style != null) {
            newSlide.elements[i] = element.copyWith(
              style: element.style!.copyWith(color: colors.text),
            );
          }
        }
      case SlideLayout.sectionHeader:
        newSlide = PresentationSlide(
          id: newId,
          index: _content!.slides.length,
          layout: SlideLayout.sectionHeader,
          background: SlideBackground.solid(colors.primary),
          elements: [
            SlideElement.text(
              id: 'section-title',
              position: ElementPosition.centerTitle(),
              text: _i18n.t('work_section_title'),
              style: SlideTextStyle(
                fontSize: 72,
                bold: true,
                align: SlideTextAlign.center,
                color: '#FFFFFF',
              ),
            ),
          ],
        );
      default:
        newSlide = PresentationSlide.blank(
          id: newId,
          index: _content!.slides.length,
          backgroundColor: colors.background,
        );
    }

    setState(() {
      _slides[newId] = newSlide;
      _content!.slides.add(newId);
      _currentSlideIndex = _content!.slides.length - 1;
      _hasChanges = true;
    });

    _updateNotesController();
  }

  Future<void> _showAddSlideDialog() async {
    final result = await showDialog<SlideLayout>(
      context: context,
      builder: (context) => _AddSlideDialog(
        i18n: _i18n,
        currentTemplate: _currentTemplate,
        onTemplateChanged: (template) {
          setState(() {
            _currentTemplate = template;
          });
        },
      ),
    );

    if (result != null) {
      _addSlide(layout: result);
    }
  }

  void _duplicateSlide() {
    if (_content == null || _currentSlide == null) return;

    final current = _currentSlide!;
    final newId = 'slide-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

    // Deep copy elements
    final newElements = current.elements.map((e) => SlideElement(
      id: '${e.id}-copy',
      type: e.type,
      position: ElementPosition(
        x: e.position.x,
        y: e.position.y,
        w: e.position.w,
        h: e.position.h,
      ),
      content: e.content.map((s) => SlideTextSpan(
        value: s.value,
        marks: Set.from(s.marks),
      )).toList(),
      style: e.style,
    )).toList();

    final newSlide = PresentationSlide(
      id: newId,
      index: _content!.slides.length,
      layout: current.layout,
      background: SlideBackground(
        type: current.background.type,
        color: current.background.color,
        image: current.background.image,
      ),
      elements: newElements,
      notes: current.notes,
    );

    setState(() {
      _slides[newId] = newSlide;
      _content!.slides.insert(_currentSlideIndex + 1, newId);
      _currentSlideIndex = _currentSlideIndex + 1;
      _hasChanges = true;
    });

    _updateNotesController();
  }

  Future<void> _deleteSlide() async {
    if (_content == null || _content!.slides.length <= 1) return;

    final slideId = _content!.slides[_currentSlideIndex];

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_delete_slide')),
        content: Text(_i18n.t('work_delete_slide_confirm')),
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
      setState(() {
        _content!.slides.removeAt(_currentSlideIndex);
        _slides.remove(slideId);

        // Update indices
        for (var i = 0; i < _content!.slides.length; i++) {
          final slide = _slides[_content!.slides[i]];
          if (slide != null) {
            slide.index = i;
          }
        }

        // Adjust current index
        if (_currentSlideIndex >= _content!.slides.length) {
          _currentSlideIndex = _content!.slides.length - 1;
        }

        _hasChanges = true;
      });

      _updateNotesController();
    }
  }

  void _reorderSlides(int oldIndex, int newIndex) {
    if (_content == null) return;

    if (newIndex > oldIndex) {
      newIndex -= 1;
    }

    setState(() {
      final slideId = _content!.slides.removeAt(oldIndex);
      _content!.slides.insert(newIndex, slideId);

      // Update indices
      for (var i = 0; i < _content!.slides.length; i++) {
        final slide = _slides[_content!.slides[i]];
        if (slide != null) {
          slide.index = i;
        }
      }

      // Keep current slide selected
      if (_currentSlideIndex == oldIndex) {
        _currentSlideIndex = newIndex;
      } else if (oldIndex < _currentSlideIndex && newIndex >= _currentSlideIndex) {
        _currentSlideIndex--;
      } else if (oldIndex > _currentSlideIndex && newIndex <= _currentSlideIndex) {
        _currentSlideIndex++;
      }

      _hasChanges = true;
    });
  }

  void _enterPresentMode() {
    setState(() {
      _isPresenting = true;
    });

    // Enter fullscreen on desktop
    if (!kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  void _exitPresentMode() {
    setState(() {
      _isPresenting = false;
    });

    // Exit fullscreen on desktop
    if (!kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  Future<void> _renameDocument() async {
    if (_metadata == null) return;

    final controller = TextEditingController(text: _metadata!.title);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('rename_document')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: _i18n.t('document_title'),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(_i18n.t('rename')),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && result != _metadata!.title) {
      setState(() {
        _metadata!.title = result;
        _hasChanges = true;
      });
    }
  }

  Future<void> _changeSlideBackground() async {
    final slide = _currentSlide;
    if (slide == null) return;

    final colors = [
      '#FFFFFF', // White
      '#000000', // Black
      '#1E3A5F', // Navy
      '#4A90D9', // Blue
      '#2ECC71', // Green
      '#F39C12', // Orange
      '#E74C3C', // Red
      '#9B59B6', // Purple
      '#1ABC9C', // Teal
      '#34495E', // Dark Gray
      '#ECF0F1', // Light Gray
      '#F5F5F5', // Off White
    ];

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_background_color')),
        content: SizedBox(
          width: 300,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: colors.map((color) {
              final isSelected = slide.background.color == color;
              return GestureDetector(
                onTap: () => Navigator.pop(context, color),
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: _parseColor(color),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outline,
                      width: isSelected ? 3 : 1,
                    ),
                  ),
                ),
              );
            }).toList(),
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

    if (result != null) {
      setState(() {
        slide.background = SlideBackground.solid(result);
        _hasChanges = true;
      });
    }
  }

  void _addTextElement() {
    final slide = _currentSlide;
    if (slide == null) return;

    final newId = 'text-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final element = SlideElement.text(
      id: newId,
      position: ElementPosition(x: '10%', y: '35%', w: '80%', h: '30%'),
      text: _i18n.t('work_enter_text'),
      style: SlideTextStyle(
        fontSize: 48,
        color: _currentTemplate.colors.text,
      ),
    );

    setState(() {
      slide.elements.add(element);
      _selectedElementId = newId;
      _hasChanges = true;
    });
  }

  Future<void> _addImageElement() async {
    final slide = _currentSlide;
    if (slide == null) return;

    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1080,
      );

      if (pickedFile == null) return;

      // Read image bytes
      final Uint8List bytes = await pickedFile.readAsBytes();

      // Generate filename from SHA1 hash
      final ext = pickedFile.path.split('.').last.toLowerCase();
      final hash = sha1.convert(bytes).toString();
      final assetPath = 'images/$hash.$ext';

      // Save to NDF archive
      await _ndfService.saveAsset(widget.filePath, assetPath, bytes);

      // Create image element
      final newId = 'img-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
      final element = SlideElement.image(
        id: newId,
        position: ElementPosition(x: '20%', y: '25%', w: '60%', h: '50%'),
        imagePath: assetPath,
      );

      setState(() {
        slide.elements.add(element);
        _selectedElementId = newId;
        _hasChanges = true;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('work_image_added'))),
        );
      }
    } catch (e) {
      LogService().log('PresentationEditorPage: Error adding image: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding image: $e')),
        );
      }
    }
  }

  SlideElement? get _selectedElement {
    final slide = _currentSlide;
    if (slide == null || _selectedElementId == null) return null;
    return slide.elements.where((e) => e.id == _selectedElementId).firstOrNull;
  }

  void _toggleBold() {
    // If in inline editing mode, use selection-aware formatting
    if (_isInlineEditing) {
      _toggleInlineFormatting('bold');
      return;
    }
    // Otherwise, toggle element-level style
    final slide = _currentSlide;
    final element = _selectedElement;
    if (slide == null || element == null) return;

    final index = slide.elements.indexWhere((e) => e.id == _selectedElementId);
    if (index >= 0) {
      final currentBold = element.style?.bold ?? false;
      setState(() {
        slide.elements[index] = element.copyWith(
          style: (element.style ?? SlideTextStyle()).copyWith(bold: !currentBold),
        );
        _hasChanges = true;
      });
    }
  }

  void _toggleItalic() {
    // If in inline editing mode, use selection-aware formatting
    if (_isInlineEditing) {
      _toggleInlineFormatting('italic');
      return;
    }
    // Otherwise, toggle element-level style
    final slide = _currentSlide;
    final element = _selectedElement;
    if (slide == null || element == null) return;

    final index = slide.elements.indexWhere((e) => e.id == _selectedElementId);
    if (index >= 0) {
      final currentItalic = element.style?.italic ?? false;
      setState(() {
        slide.elements[index] = element.copyWith(
          style: (element.style ?? SlideTextStyle()).copyWith(italic: !currentItalic),
        );
        _hasChanges = true;
      });
    }
  }

  void _setAlignment(SlideTextAlign align) {
    final slide = _currentSlide;
    final element = _selectedElement;
    if (slide == null || element == null) return;

    final index = slide.elements.indexWhere((e) => e.id == _selectedElementId);
    if (index >= 0) {
      setState(() {
        slide.elements[index] = element.copyWith(
          style: (element.style ?? SlideTextStyle()).copyWith(align: align),
        );
        _hasChanges = true;
      });
    }
  }

  void _setVerticalAlignment(SlideVerticalAlign vAlign) {
    final slide = _currentSlide;
    final element = _selectedElement;
    if (slide == null || element == null) return;

    final index = slide.elements.indexWhere((e) => e.id == _selectedElementId);
    if (index >= 0) {
      setState(() {
        slide.elements[index] = element.copyWith(
          style: (element.style ?? SlideTextStyle()).copyWith(vAlign: vAlign),
        );
        _hasChanges = true;
      });
    }
  }

  void _setFontSize(int size) {
    final slide = _currentSlide;
    final element = _selectedElement;
    if (slide == null || element == null) return;

    final index = slide.elements.indexWhere((e) => e.id == _selectedElementId);
    if (index >= 0) {
      setState(() {
        slide.elements[index] = element.copyWith(
          style: (element.style ?? SlideTextStyle()).copyWith(fontSize: size),
        );
        _hasChanges = true;
      });
    }
  }

  Future<void> _setTextColor() async {
    final element = _selectedElement;
    if (element == null) return;

    final colors = [
      '#000000', '#FFFFFF', '#FF0000', '#00FF00', '#0000FF',
      '#FFFF00', '#FF00FF', '#00FFFF', '#FF6600', '#6600FF',
      '#333333', '#666666', '#999999', '#CCCCCC',
      _currentTemplate.colors.text,
      _currentTemplate.colors.primary,
      _currentTemplate.colors.secondary,
      _currentTemplate.colors.accent,
    ];

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('text_color')),
        content: SizedBox(
          width: 280,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: colors.map((color) {
              final isSelected = element.style?.color == color;
              return GestureDetector(
                onTap: () => Navigator.pop(context, color),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _parseColor(color),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outline,
                      width: isSelected ? 3 : 1,
                    ),
                  ),
                ),
              );
            }).toList(),
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

    if (result != null) {
      final slide = _currentSlide;
      if (slide == null) return;

      final index = slide.elements.indexWhere((e) => e.id == _selectedElementId);
      if (index >= 0) {
        setState(() {
          slide.elements[index] = element.copyWith(
            style: (element.style ?? SlideTextStyle()).copyWith(color: result),
          );
          _hasChanges = true;
        });
      }
    }
  }

  void _editSelectedElement() {
    if (_selectedElementId == null) return;
    _editElement(_selectedElementId!);
  }

  void _editElement(String elementId) {
    final slide = _currentSlide;
    if (slide == null) return;

    final element = slide.elements.firstWhere(
      (e) => e.id == elementId,
      orElse: () => slide.elements.first,
    );

    // Only allow inline editing for text elements
    if (element.type != SlideElementType.text) return;

    // Check for placeholder text
    final currentText = element.plainText;
    final placeholderText = _i18n.t('work_enter_text');
    final initialText = currentText == placeholderText ? '' : currentText;

    // Store original spans for cancel operation (deep copy)
    _originalSpansBeforeEdit = element.content
        .map((s) => SlideTextSpan(value: s.value, marks: Set<String>.from(s.marks)))
        .toList();

    // Enter inline editing mode
    setState(() {
      _selectedElementId = elementId;
      _isInlineEditing = true;
    });

    _textEditController.text = initialText;

    // Request focus after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _textEditFocusNode.requestFocus();
      // Select all text for easy replacement
      _textEditController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _textEditController.text.length,
      );
    });
  }

  void _commitInlineEdit() {
    if (!_isInlineEditing || _selectedElementId == null) return;

    final slide = _currentSlide;
    if (slide == null) return;

    final index = slide.elements.indexWhere((e) => e.id == _selectedElementId);
    if (index >= 0) {
      final element = slide.elements[index];
      final currentText = _textEditController.text;

      if (currentText.isEmpty) {
        // Empty text - use placeholder
        slide.elements[index] = element.copyWith(
          content: [SlideTextSpan(value: _i18n.t('work_enter_text'))],
        );
      } else {
        // Check if text has changed from the span content
        final existingText = element.content.map((s) => s.value).join();

        if (currentText == existingText) {
          // Text unchanged - preserve existing spans with formatting
          // (formatting may have been applied via Ctrl+B/I)
        } else {
          // Text was edited - replace with single span
          // Preserve any element-level formatting that was applied
          slide.elements[index] = element.copyWith(
            content: [SlideTextSpan(value: currentText)],
          );
        }
      }
      _hasChanges = true;
    }

    setState(() {
      _isInlineEditing = false;
      _originalSpansBeforeEdit = null;
    });
  }

  void _cancelInlineEdit() {
    if (!_isInlineEditing) return;

    // Restore original spans if we have them
    if (_originalSpansBeforeEdit != null && _selectedElementId != null) {
      final slide = _currentSlide;
      if (slide != null) {
        final index = slide.elements.indexWhere((e) => e.id == _selectedElementId);
        if (index >= 0) {
          final element = slide.elements[index];
          slide.elements[index] = element.copyWith(
            content: _originalSpansBeforeEdit!,
          );
        }
      }
    }

    setState(() {
      _isInlineEditing = false;
      _originalSpansBeforeEdit = null;
    });
  }

  /// Toggle formatting (bold, italic, underline) during inline editing.
  /// If text is selected, applies to selection only; otherwise toggles element style.
  void _toggleInlineFormatting(String mark) {
    if (!_isInlineEditing || _selectedElementId == null) return;

    final slide = _currentSlide;
    if (slide == null) return;

    final index = slide.elements.indexWhere((e) => e.id == _selectedElementId);
    if (index < 0) return;

    final element = slide.elements[index];
    final selection = _textEditController.selection;
    final text = _textEditController.text;

    // If no text selection (collapsed cursor), toggle element-level style
    if (!selection.isValid || selection.isCollapsed || text.isEmpty) {
      _toggleElementStyle(mark);
      return;
    }

    // Get selection bounds
    final start = selection.start;
    final end = selection.end;

    // Build a character-level map of marks from existing spans
    final charMarks = <int, Set<String>>{};
    int pos = 0;
    for (final span in element.content) {
      for (int i = 0; i < span.value.length && pos < text.length; i++) {
        charMarks[pos] = Set<String>.from(span.marks);
        pos++;
      }
    }
    // Fill remaining characters (if text was edited) with empty marks
    for (int i = pos; i < text.length; i++) {
      charMarks[i] = <String>{};
    }

    // Check if ALL characters in selection have this mark
    bool allHaveMark = true;
    for (int i = start; i < end; i++) {
      if (!(charMarks[i]?.contains(mark) ?? false)) {
        allHaveMark = false;
        break;
      }
    }

    // Toggle the mark on the selection only
    for (int i = start; i < end; i++) {
      charMarks[i] ??= <String>{};
      if (allHaveMark) {
        charMarks[i]!.remove(mark);
      } else {
        charMarks[i]!.add(mark);
      }
    }

    // Convert back to spans - merge consecutive characters with same marks
    final newSpans = <SlideTextSpan>[];
    if (text.isNotEmpty) {
      int spanStart = 0;
      Set<String> currentMarks = Set<String>.from(charMarks[0] ?? {});

      for (int i = 1; i <= text.length; i++) {
        final marks = i < text.length ? charMarks[i] : null;

        // If marks changed or end of text, create a span
        if (marks == null || !_setsEqual(marks, currentMarks)) {
          newSpans.add(SlideTextSpan(
            value: text.substring(spanStart, i),
            marks: currentMarks.isNotEmpty ? Set<String>.from(currentMarks) : null,
          ));
          if (marks != null) {
            spanStart = i;
            currentMarks = Set<String>.from(marks);
          }
        }
      }
    }

    setState(() {
      slide.elements[index] = element.copyWith(content: newSpans);
      _hasChanges = true;
    });
  }

  bool _setsEqual(Set<String>? a, Set<String>? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  void _toggleElementStyle(String mark) {
    final slide = _currentSlide;
    final element = _selectedElement;
    if (slide == null || element == null) return;

    final index = slide.elements.indexWhere((e) => e.id == _selectedElementId);
    if (index < 0) return;

    SlideTextStyle newStyle;
    switch (mark) {
      case 'bold':
        final currentBold = element.style?.bold ?? false;
        newStyle = (element.style ?? SlideTextStyle()).copyWith(bold: !currentBold);
      case 'italic':
        final currentItalic = element.style?.italic ?? false;
        newStyle = (element.style ?? SlideTextStyle()).copyWith(italic: !currentItalic);
      default:
        return;
    }

    setState(() {
      slide.elements[index] = element.copyWith(style: newStyle);
      _hasChanges = true;
    });
  }

  void _deleteSelectedElement() {
    final slide = _currentSlide;
    if (slide == null || _selectedElementId == null) return;

    setState(() {
      slide.elements.removeWhere((e) => e.id == _selectedElementId);
      _selectedElementId = null;
      _hasChanges = true;
    });
  }

  void _updateElement(String elementId, SlideElement updatedElement) {
    final slide = _currentSlide;
    if (slide == null) return;

    final index = slide.elements.indexWhere((e) => e.id == elementId);
    if (index >= 0) {
      setState(() {
        slide.elements[index] = updatedElement;
        _hasChanges = true;
      });
    }
  }

  bool get _isDesktop {
    if (kIsWeb) return false;
    return Platform.isLinux || Platform.isWindows || Platform.isMacOS;
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

  Color _parseColor(String colorStr) {
    if (colorStr.startsWith('#')) {
      final hex = colorStr.substring(1);
      if (hex.length == 6) {
        return Color(int.parse('FF$hex', radix: 16));
      } else if (hex.length == 8) {
        return Color(int.parse(hex, radix: 16));
      }
    }
    return Colors.white;
  }

  @override
  Widget build(BuildContext context) {
    if (_isPresenting) {
      return _buildPresentMode(context);
    }

    final theme = Theme.of(context);

    return PopScope(
      canPop: !_hasChanges,
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop) {
          final shouldPop = await _onWillPop();
          if (shouldPop && mounted) {
            Navigator.of(context).pop();
          }
        }
      },
      child: KeyboardListener(
        focusNode: FocusNode(),
        onKeyEvent: _handleKeyEvent,
        child: Scaffold(
          appBar: AppBar(
            title: GestureDetector(
              onTap: _isDesktop ? _renameDocument : null,
              onLongPress: _isDesktop ? null : _renameDocument,
              child: Text(_metadata?.title ?? widget.title ?? _i18n.t('work_presentation')),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.play_arrow),
                onPressed: _enterPresentMode,
                tooltip: '${_i18n.t('work_present')} (F5)',
              ),
              IconButton(
                icon: Icon(
                  _hasChanges ? Icons.save : Icons.save_outlined,
                  color: _hasChanges ? null : theme.disabledColor,
                ),
                onPressed: _save,
                tooltip: '${_i18n.t('save')} (Ctrl+S)',
              ),
            ],
          ),
          body: _buildBody(theme),
        ),
      ),
    );
  }

  Widget _buildPresentMode(BuildContext context) {
    return KeyboardListener(
      focusNode: FocusNode(),
      onKeyEvent: _handleKeyEvent,
      autofocus: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: _nextSlide,
          onDoubleTap: _exitPresentMode,
          child: Center(
            child: _currentSlide != null && _content != null
                ? SlidePresenterCanvas(
                    slide: _currentSlide!,
                    theme: _content!.theme,
                    template: _currentTemplate,
                    aspectRatio: _content!.aspectRatioValue,
                    imageLoader: (assetPath) => _ndfService.readAsset(widget.filePath, assetPath),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
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

    if (_content == null) {
      return Center(
        child: Text(_i18n.t('error_loading_document')),
      );
    }

    return Column(
      children: [
        // Main editor area
        Expanded(
          child: Row(
            children: [
              // Slide panel (left)
              _buildSlidePanel(theme),
              // Divider
              VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
              // Main canvas area
              Expanded(
                child: Column(
                  children: [
                    // Canvas
                    Expanded(
                      child: _buildCanvasArea(theme),
                    ),
                    // Toolbar
                    if (_selectedElementId != null)
                      _buildElementToolbar(theme),
                  ],
                ),
              ),
            ],
          ),
        ),
        // Notes area (bottom)
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        _buildNotesArea(theme),
      ],
    );
  }

  Widget _buildSlidePanel(ThemeData theme) {
    return SizedBox(
      width: 150,
      child: Column(
        children: [
          // Slide list
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _content!.slides.length,
              onReorder: _reorderSlides,
              itemBuilder: (context, index) {
                final slideId = _content!.slides[index];
                final slide = _slides[slideId];
                if (slide == null) {
                  return SizedBox.shrink(key: ValueKey(slideId));
                }

                return DraggableSlideThumbnail(
                  key: ValueKey(slideId),
                  slide: slide,
                  theme: _content!.theme,
                  template: _currentTemplate,
                  aspectRatio: _content!.aspectRatioValue,
                  isSelected: index == _currentSlideIndex,
                  slideNumber: index + 1,
                  index: index,
                  imageLoader: (assetPath) => _ndfService.readAsset(widget.filePath, assetPath),
                  onTap: () => _goToSlide(index),
                );
              },
            ),
          ),
          // Add slide button
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _showAddSlideDialog,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(_i18n.t('work_add_slide')),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvasArea(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          // Office 2000-style main toolbar
          _buildMainToolbar(theme),
          // Slide navigation bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                bottom: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                // Slide navigation
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios, size: 16),
                  onPressed: _currentSlideIndex > 0 ? _previousSlide : null,
                  tooltip: _i18n.t('work_previous_slide'),
                  visualDensity: VisualDensity.compact,
                ),
                Text(
                  '${_currentSlideIndex + 1} / ${_content!.slides.length}',
                  style: theme.textTheme.bodySmall,
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward_ios, size: 16),
                  onPressed: _currentSlideIndex < _content!.slides.length - 1
                      ? _nextSlide
                      : null,
                  tooltip: _i18n.t('work_next_slide'),
                  visualDensity: VisualDensity.compact,
                ),
                const Spacer(),
                // Current template indicator
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: _parseColor(_currentTemplate.colors.primary).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: _parseColor(_currentTemplate.colors.primary).withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: _parseColor(_currentTemplate.colors.primary),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _i18n.t(_currentTemplate.nameKey),
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // More actions
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 20),
                  tooltip: _i18n.t('more'),
                  onSelected: (action) {
                    switch (action) {
                      case 'duplicate':
                        _duplicateSlide();
                      case 'delete':
                        _deleteSlide();
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'duplicate',
                      child: Row(
                        children: [
                          const Icon(Icons.content_copy, size: 18),
                          const SizedBox(width: 8),
                          Text(_i18n.t('work_duplicate_slide')),
                        ],
                      ),
                    ),
                    if (_content!.slides.length > 1)
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline, size: 18, color: theme.colorScheme.error),
                            const SizedBox(width: 8),
                            Text(
                              _i18n.t('work_delete_slide'),
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          // Canvas
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: _currentSlide != null
                    ? GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () {
                          if (_isInlineEditing) {
                            _commitInlineEdit();
                          } else if (_selectedElementId != null) {
                            setState(() {
                              _selectedElementId = null;
                            });
                          }
                        },
                        child: SlideCanvasWidget(
                          slide: _currentSlide!,
                          theme: _content!.theme,
                          template: _currentTemplate,
                          aspectRatio: _content!.aspectRatioValue,
                          selectedElementId: _selectedElementId,
                          isEditing: true,
                          isInlineEditing: _isInlineEditing,
                          textEditController: _textEditController,
                          textEditFocusNode: _textEditFocusNode,
                          onTextEditSubmit: _commitInlineEdit,
                          onTextEditCancel: _cancelInlineEdit,
                          onToggleFormatting: _toggleInlineFormatting,
                          imageLoader: (assetPath) => _ndfService.readAsset(widget.filePath, assetPath),
                          onElementTap: (elementId) {
                            if (_isInlineEditing) {
                              // Clicking on another element commits current edit
                              _commitInlineEdit();
                            }
                            setState(() {
                              _selectedElementId = elementId;
                            });
                          },
                          onElementDoubleTap: (elementId) {
                            _editElement(elementId);
                          },
                          onElementChanged: (elementId, updatedElement) {
                            _updateElement(elementId, updatedElement);
                          },
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildElementToolbar(ThemeData theme) {
    final element = _selectedElement;
    final currentAlign = element?.style?.align ?? SlideTextAlign.left;
    final currentVAlign = element?.style?.vAlign ?? SlideVerticalAlign.top;
    final isBold = element?.style?.bold ?? false;
    final isItalic = element?.style?.italic ?? false;
    final fontSize = element?.style?.fontSize ?? 24;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            // Edit text button
            _ToolbarButton(
              icon: Icons.edit,
              tooltip: _i18n.t('work_edit_text'),
              onPressed: _editSelectedElement,
            ),
            _toolbarDivider(theme),

            // Font size dropdown
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: DropdownButton<int>(
                value: fontSize,
                underline: const SizedBox.shrink(),
                isDense: true,
                items: [12, 14, 16, 18, 20, 24, 28, 32, 36, 42, 48, 56, 64, 72, 96]
                    .map((size) => DropdownMenuItem(
                          value: size,
                          child: Text('$size', style: const TextStyle(fontSize: 13)),
                        ))
                    .toList(),
                onChanged: (size) {
                  if (size != null) _setFontSize(size);
                },
              ),
            ),
            _toolbarDivider(theme),

            // Bold
            _ToolbarButton(
              icon: Icons.format_bold,
              tooltip: _i18n.t('bold'),
              isActive: isBold,
              onPressed: _toggleBold,
            ),
            // Italic
            _ToolbarButton(
              icon: Icons.format_italic,
              tooltip: _i18n.t('italic'),
              isActive: isItalic,
              onPressed: _toggleItalic,
            ),
            _toolbarDivider(theme),

            // Alignment
            _ToolbarButton(
              icon: Icons.format_align_left,
              tooltip: _i18n.t('work_align_left'),
              isActive: currentAlign == SlideTextAlign.left,
              onPressed: () => _setAlignment(SlideTextAlign.left),
            ),
            _ToolbarButton(
              icon: Icons.format_align_center,
              tooltip: _i18n.t('work_align_center'),
              isActive: currentAlign == SlideTextAlign.center,
              onPressed: () => _setAlignment(SlideTextAlign.center),
            ),
            _ToolbarButton(
              icon: Icons.format_align_right,
              tooltip: _i18n.t('work_align_right'),
              isActive: currentAlign == SlideTextAlign.right,
              onPressed: () => _setAlignment(SlideTextAlign.right),
            ),
            _toolbarDivider(theme),

            // Vertical alignment
            _ToolbarButton(
              icon: Icons.vertical_align_top,
              tooltip: _i18n.t('work_valign_top'),
              isActive: currentVAlign == SlideVerticalAlign.top,
              onPressed: () => _setVerticalAlignment(SlideVerticalAlign.top),
            ),
            _ToolbarButton(
              icon: Icons.vertical_align_center,
              tooltip: _i18n.t('work_valign_center'),
              isActive: currentVAlign == SlideVerticalAlign.center,
              onPressed: () => _setVerticalAlignment(SlideVerticalAlign.center),
            ),
            _ToolbarButton(
              icon: Icons.vertical_align_bottom,
              tooltip: _i18n.t('work_valign_bottom'),
              isActive: currentVAlign == SlideVerticalAlign.bottom,
              onPressed: () => _setVerticalAlignment(SlideVerticalAlign.bottom),
            ),
            _toolbarDivider(theme),

            // Text color
            _ToolbarButton(
              icon: Icons.format_color_text,
              tooltip: _i18n.t('text_color'),
              onPressed: _setTextColor,
            ),
            _toolbarDivider(theme),

            // Delete element
            _ToolbarButton(
              icon: Icons.delete_outline,
              tooltip: _i18n.t('delete'),
              color: theme.colorScheme.error,
              onPressed: _deleteSelectedElement,
            ),

            const SizedBox(width: 16),
            // Deselect
            TextButton.icon(
              onPressed: () {
                setState(() {
                  _selectedElementId = null;
                });
              },
              icon: const Icon(Icons.close, size: 16),
              label: Text(_i18n.t('work_deselect')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbarDivider(ThemeData theme) {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: theme.colorScheme.outlineVariant,
    );
  }

  /// Office 2000-style main toolbar
  Widget _buildMainToolbar(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            // INSERT section
            _ToolbarSection(
              label: _i18n.t('work_insert'),
              children: [
                _ToolbarButton(
                  icon: Icons.text_fields,
                  tooltip: _i18n.t('work_add_text'),
                  onPressed: _addTextElement,
                ),
                _ToolbarButton(
                  icon: Icons.image,
                  tooltip: _i18n.t('work_add_image'),
                  onPressed: _addImageElement,
                ),
              ],
            ),
            _toolbarDivider(theme),

            // SLIDE section
            _ToolbarSection(
              label: _i18n.t('work_slide'),
              children: [
                _ToolbarButton(
                  icon: Icons.format_color_fill,
                  tooltip: _i18n.t('work_background_color'),
                  onPressed: _changeSlideBackground,
                ),
                _ToolbarButton(
                  icon: Icons.palette,
                  tooltip: _i18n.t('work_change_template'),
                  onPressed: _showTemplateDialog,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showTemplateDialog() async {
    final result = await showDialog<SlideTemplate>(
      context: context,
      builder: (context) => _TemplatePickerDialog(
        i18n: _i18n,
        currentTemplate: _currentTemplate,
      ),
    );

    if (result != null) {
      setState(() {
        _currentTemplate = result;
      });

      // Optionally apply template to current slide
      final applyToSlide = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_i18n.t('work_apply_template')),
          content: Text(_i18n.t('work_apply_template_question')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(_i18n.t('no')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(_i18n.t('yes')),
            ),
          ],
        ),
      );

      if (applyToSlide == true) {
        _applyTemplateToCurrentSlide();
      }
    }
  }

  void _applyTemplateToCurrentSlide() {
    final slide = _currentSlide;
    if (slide == null) return;

    final colors = _currentTemplate.colors;

    setState(() {
      // Update background
      slide.background = SlideBackground.solid(colors.background);

      // Update text colors
      for (var i = 0; i < slide.elements.length; i++) {
        final element = slide.elements[i];
        if (element.type == SlideElementType.text) {
          slide.elements[i] = element.copyWith(
            style: (element.style ?? SlideTextStyle()).copyWith(
              color: colors.text,
            ),
          );
        }
      }

      _hasChanges = true;
    });
  }

  Widget _buildNotesArea(ThemeData theme) {
    return Container(
      height: 100,
      padding: const EdgeInsets.all(8),
      child: TextField(
        controller: _notesController,
        focusNode: _notesFocusNode,
        maxLines: null,
        expands: true,
        decoration: InputDecoration(
          hintText: _i18n.t('work_speaker_notes'),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        onChanged: (value) {
          if (!_hasChanges) {
            setState(() {
              _hasChanges = true;
            });
          }
        },
      ),
    );
  }
}

// ============================================================
// HELPER WIDGETS
// ============================================================

/// Office 2000-style toolbar button
class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool isActive;
  final Color? color;

  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.isActive = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: isActive
                ? theme.colorScheme.primaryContainer
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: isActive
                ? Border.all(color: theme.colorScheme.primary)
                : null,
          ),
          child: Icon(
            icon,
            size: 18,
            color: color ??
                (isActive
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface),
          ),
        ),
      ),
    );
  }
}

/// Toolbar section with label
class _ToolbarSection extends StatelessWidget {
  final String label;
  final List<Widget> children;

  const _ToolbarSection({
    required this.label,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 9,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Add slide dialog with template and layout selection
class _AddSlideDialog extends StatefulWidget {
  final I18nService i18n;
  final SlideTemplate currentTemplate;
  final void Function(SlideTemplate) onTemplateChanged;

  const _AddSlideDialog({
    required this.i18n,
    required this.currentTemplate,
    required this.onTemplateChanged,
  });

  @override
  State<_AddSlideDialog> createState() => _AddSlideDialogState();
}

class _AddSlideDialogState extends State<_AddSlideDialog> {
  late SlideTemplate _selectedTemplate;
  SlideLayout _selectedLayout = SlideLayout.blank;

  @override
  void initState() {
    super.initState();
    _selectedTemplate = widget.currentTemplate;
  }

  Color _parseColor(String? colorStr) {
    if (colorStr == null || colorStr.isEmpty) return Colors.white;
    if (colorStr.startsWith('#')) {
      final hex = colorStr.substring(1);
      if (hex.length == 6) {
        return Color(int.parse('FF$hex', radix: 16));
      }
    }
    return Colors.white;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(widget.i18n.t('work_add_slide')),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Layout selection
            Text(
              widget.i18n.t('work_layout'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _LayoutOption(
                  layout: SlideLayout.blank,
                  label: widget.i18n.t('work_layout_blank'),
                  icon: Icons.crop_landscape,
                  isSelected: _selectedLayout == SlideLayout.blank,
                  onTap: () => setState(() => _selectedLayout = SlideLayout.blank),
                ),
                _LayoutOption(
                  layout: SlideLayout.title,
                  label: widget.i18n.t('work_layout_title'),
                  icon: Icons.title,
                  isSelected: _selectedLayout == SlideLayout.title,
                  onTap: () => setState(() => _selectedLayout = SlideLayout.title),
                ),
                _LayoutOption(
                  layout: SlideLayout.titleContent,
                  label: widget.i18n.t('work_layout_title_content'),
                  icon: Icons.view_agenda,
                  isSelected: _selectedLayout == SlideLayout.titleContent,
                  onTap: () => setState(() => _selectedLayout = SlideLayout.titleContent),
                ),
                _LayoutOption(
                  layout: SlideLayout.sectionHeader,
                  label: widget.i18n.t('work_layout_section'),
                  icon: Icons.horizontal_rule,
                  isSelected: _selectedLayout == SlideLayout.sectionHeader,
                  onTap: () => setState(() => _selectedLayout = SlideLayout.sectionHeader),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Template selection
            Text(
              widget.i18n.t('work_template'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 150,
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 1.2,
                ),
                itemCount: SlideTemplate.templates.length,
                itemBuilder: (context, index) {
                  final template = SlideTemplate.templates[index];
                  final isSelected = template.id == _selectedTemplate.id;

                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _selectedTemplate = template;
                      });
                      widget.onTemplateChanged(template);
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: _parseColor(template.colors.background),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: isSelected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outline,
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 24,
                            height: 4,
                            margin: const EdgeInsets.only(bottom: 4),
                            decoration: BoxDecoration(
                              color: _parseColor(template.colors.primary),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          Container(
                            width: 32,
                            height: 2,
                            margin: const EdgeInsets.only(bottom: 2),
                            color: _parseColor(template.colors.text),
                          ),
                          Container(
                            width: 28,
                            height: 2,
                            color: _parseColor(template.colors.secondary),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                widget.i18n.t(_selectedTemplate.nameKey),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.i18n.t('cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selectedLayout),
          child: Text(widget.i18n.t('work_add_slide')),
        ),
      ],
    );
  }
}

/// Layout option button
class _LayoutOption extends StatelessWidget {
  final SlideLayout layout;
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _LayoutOption({
    required this.layout,
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 80,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 24,
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Template picker dialog
class _TemplatePickerDialog extends StatelessWidget {
  final I18nService i18n;
  final SlideTemplate currentTemplate;

  const _TemplatePickerDialog({
    required this.i18n,
    required this.currentTemplate,
  });

  Color _parseColor(String? colorStr) {
    if (colorStr == null || colorStr.isEmpty) return Colors.white;
    if (colorStr.startsWith('#')) {
      final hex = colorStr.substring(1);
      if (hex.length == 6) {
        return Color(int.parse('FF$hex', radix: 16));
      }
    }
    return Colors.white;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(i18n.t('work_choose_template')),
      content: SizedBox(
        width: 400,
        height: 300,
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.4,
          ),
          itemCount: SlideTemplate.templates.length,
          itemBuilder: (context, index) {
            final template = SlideTemplate.templates[index];
            final isSelected = template.id == currentTemplate.id;

            return GestureDetector(
              onTap: () => Navigator.pop(context, template),
              child: Container(
                decoration: BoxDecoration(
                  color: _parseColor(template.colors.background),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSelected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                    width: isSelected ? 3 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Mini slide preview
                    Container(
                      width: 48,
                      height: 6,
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: BoxDecoration(
                        color: _parseColor(template.colors.primary),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Container(
                      width: 64,
                      height: 3,
                      margin: const EdgeInsets.only(bottom: 3),
                      color: _parseColor(template.colors.text),
                    ),
                    Container(
                      width: 56,
                      height: 3,
                      margin: const EdgeInsets.only(bottom: 8),
                      color: _parseColor(template.colors.secondary),
                    ),
                    // Template name
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        i18n.t(template.nameKey),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white,
                          fontSize: 9,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(i18n.t('cancel')),
        ),
      ],
    );
  }
}
