/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'element_position.dart';

/// Types of elements that can be placed on a scene
enum ElementType {
  /// Text box with styling
  text,

  /// Large stylized title with flashy fonts
  title,

  /// Interactive button
  button,

  /// Interactive quiz with question/answer
  quiz,
}

/// Button shapes available for button elements
enum ButtonShape {
  /// Rectangular button with sharp corners
  rectangle,

  /// Rectangle with rounded corners
  roundedRect,

  /// Circular button
  circle,

  /// Small circular indicator with optional label
  dot,

  /// Invisible touch area (shown with red dotted border in Studio)
  invisible,
}

/// Font sizes for text elements
enum FontSize {
  /// 14sp
  small,

  /// 18sp
  medium,

  /// 24sp
  large,

  /// 32sp
  xlarge,

  /// 48sp
  title,
}

/// Label position for dot buttons
enum LabelPosition {
  right,
  left,
  top,
  bottom,
}

/// Flashy font styles for title elements
enum TitleFont {
  /// Bold sans-serif (default)
  bold,

  /// Elegant serif style
  serif,

  /// Handwritten/script style
  handwritten,

  /// Retro/display style
  retro,

  /// Modern condensed
  condensed,
}

/// A visual element placed on a scene.
class StoryElement {
  /// Unique element identifier
  final String id;

  /// Type of element
  final ElementType type;

  /// When this element appears (ms from scene start, 0-5000)
  final int appearAt;

  /// Position and size on screen
  final ElementPosition position;

  /// Type-specific properties
  final Map<String, dynamic> properties;

  const StoryElement({
    required this.id,
    required this.type,
    this.appearAt = 0,
    required this.position,
    this.properties = const {},
  });

  // ============ Text Element Helpers ============

  /// Create a text element
  factory StoryElement.text({
    required String id,
    required String text,
    int appearAt = 0,
    required ElementPosition position,
    FontSize fontSize = FontSize.medium,
    String fontWeight = 'normal',
    String color = '#FFFFFF',
    String align = 'left',
    String? backgroundColor,
  }) {
    return StoryElement(
      id: id,
      type: ElementType.text,
      appearAt: appearAt,
      position: position,
      properties: {
        'text': text,
        'fontSize': fontSize.name,
        'fontWeight': fontWeight,
        'color': color,
        'align': align,
        if (backgroundColor != null) 'backgroundColor': backgroundColor,
      },
    );
  }

  /// Get text content
  String? get text => properties['text'] as String?;

  /// Get font size
  FontSize get fontSize {
    final value = properties['fontSize'] as String?;
    return FontSize.values.firstWhere(
      (e) => e.name == value,
      orElse: () => FontSize.medium,
    );
  }

  /// Get font size in sp
  double get fontSizeSp {
    switch (fontSize) {
      case FontSize.small:
        return 14;
      case FontSize.medium:
        return 18;
      case FontSize.large:
        return 24;
      case FontSize.xlarge:
        return 32;
      case FontSize.title:
        return 48;
    }
  }

  // ============ Title Element Helpers ============

  /// Create a title element with large flashy text
  factory StoryElement.title({
    required String id,
    required String text,
    int appearAt = 0,
    required ElementPosition position,
    TitleFont font = TitleFont.bold,
    String color = '#FFFF00',
    String? strokeColor,
    String? shadowColor,
    String align = 'center',
  }) {
    return StoryElement(
      id: id,
      type: ElementType.title,
      appearAt: appearAt,
      position: position,
      properties: {
        'text': text,
        'font': font.name,
        'color': color,
        if (strokeColor != null) 'strokeColor': strokeColor,
        if (shadowColor != null) 'shadowColor': shadowColor,
        'align': align,
      },
    );
  }

  /// Get title font style
  TitleFont get titleFont {
    final value = properties['font'] as String?;
    return TitleFont.values.firstWhere(
      (e) => e.name == value,
      orElse: () => TitleFont.bold,
    );
  }

  // ============ Button Element Helpers ============

  /// Create a button element
  factory StoryElement.button({
    required String id,
    required ButtonShape shape,
    int appearAt = 0,
    required ElementPosition position,
    String? label,
    String? backgroundColor,
    String? textColor,
    LabelPosition labelPosition = LabelPosition.right,
  }) {
    return StoryElement(
      id: id,
      type: ElementType.button,
      appearAt: appearAt,
      position: position,
      properties: {
        'shape': shape.name,
        if (label != null) 'label': label,
        if (backgroundColor != null) 'backgroundColor': backgroundColor,
        if (textColor != null) 'textColor': textColor,
        if (shape == ButtonShape.dot) 'labelPosition': labelPosition.name,
      },
    );
  }

  /// Get button shape
  ButtonShape get buttonShape {
    final value = properties['shape'] as String?;
    return ButtonShape.values.firstWhere(
      (e) => e.name == value,
      orElse: () => ButtonShape.roundedRect,
    );
  }

  /// Get button label
  String? get label => properties['label'] as String?;

  /// Check if button is invisible
  bool get isInvisible => buttonShape == ButtonShape.invisible;

  // ============ Quiz Element Helpers ============

  /// Create a quiz element with question and answer
  factory StoryElement.quiz({
    required String id,
    required String question,
    required String answer,
    int appearAt = 0,
    required ElementPosition position,
    TitleFont font = TitleFont.bold,
    String color = '#FFFFFF',
  }) {
    return StoryElement(
      id: id,
      type: ElementType.quiz,
      appearAt: appearAt,
      position: position,
      properties: {
        'question': question,
        'answer': answer,
        'font': font.name,
        'color': color,
      },
    );
  }

  /// Get quiz question text
  String? get quizQuestion => properties['question'] as String?;

  /// Get quiz answer
  String? get quizAnswer => properties['answer'] as String?;

  /// Get quiz font style (reuses TitleFont)
  TitleFont get quizFont {
    final value = properties['font'] as String?;
    return TitleFont.values.firstWhere(
      (e) => e.name == value,
      orElse: () => TitleFont.bold,
    );
  }

  factory StoryElement.fromJson(Map<String, dynamic> json) {
    return StoryElement(
      id: json['id'] as String,
      type: ElementType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => ElementType.text,
      ),
      appearAt: (json['appearAt'] as num?)?.toInt() ?? 0,
      position: ElementPosition.fromJson(
        json['position'] as Map<String, dynamic>,
      ),
      properties: Map<String, dynamic>.from(json['properties'] ?? {}),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'appearAt': appearAt,
      'position': position.toJson(),
      'properties': properties,
    };
  }

  StoryElement copyWith({
    String? id,
    ElementType? type,
    int? appearAt,
    ElementPosition? position,
    Map<String, dynamic>? properties,
  }) {
    return StoryElement(
      id: id ?? this.id,
      type: type ?? this.type,
      appearAt: appearAt ?? this.appearAt,
      position: position ?? this.position,
      properties: properties ?? this.properties,
    );
  }
}
