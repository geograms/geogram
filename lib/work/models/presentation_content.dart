/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';

/// Slide layout types
enum SlideLayout {
  blank,
  title,
  titleContent,
  twoColumn,
  sectionHeader,
}

/// Types of slide elements
enum SlideElementType {
  text,
  image,
}

/// Text alignment for slide elements
enum SlideTextAlign {
  left,
  center,
  right,
}

/// Vertical alignment for slide text elements
enum SlideVerticalAlign {
  top,
  center,
  bottom,
}

/// Position of an element on the slide (percentage-based)
class ElementPosition {
  final String x;
  final String y;
  final String w;
  final String h;

  ElementPosition({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  factory ElementPosition.fromJson(Map<String, dynamic> json) {
    return ElementPosition(
      x: json['x'] as String? ?? '0%',
      y: json['y'] as String? ?? '0%',
      w: json['w'] as String? ?? '100%',
      h: json['h'] as String? ?? '100%',
    );
  }

  Map<String, dynamic> toJson() => {
    'x': x,
    'y': y,
    'w': w,
    'h': h,
  };

  /// Parse percentage value to double (0.0 - 1.0)
  static double parsePercent(String value) {
    final cleaned = value.replaceAll('%', '').trim();
    return (double.tryParse(cleaned) ?? 0) / 100;
  }

  double get xPercent => parsePercent(x);
  double get yPercent => parsePercent(y);
  double get wPercent => parsePercent(w);
  double get hPercent => parsePercent(h);

  /// Create a position with default values for different layout zones
  factory ElementPosition.titleZone() => ElementPosition(
    x: '5%', y: '5%', w: '90%', h: '20%',
  );

  factory ElementPosition.contentZone() => ElementPosition(
    x: '5%', y: '30%', w: '90%', h: '60%',
  );

  factory ElementPosition.fullSlide() => ElementPosition(
    x: '0%', y: '0%', w: '100%', h: '100%',
  );

  factory ElementPosition.centerTitle() => ElementPosition(
    x: '10%', y: '35%', w: '80%', h: '30%',
  );
}

/// Text styling for slide elements
class SlideTextStyle {
  final String? color;
  final int? fontSize;
  final SlideTextAlign? align;
  final SlideVerticalAlign? vAlign;
  final bool? bold;
  final bool? italic;

  SlideTextStyle({
    this.color,
    this.fontSize,
    this.align,
    this.vAlign,
    this.bold,
    this.italic,
  });

  factory SlideTextStyle.fromJson(Map<String, dynamic> json) {
    SlideTextAlign? align;
    if (json['align'] != null) {
      align = SlideTextAlign.values.firstWhere(
        (a) => a.name == json['align'],
        orElse: () => SlideTextAlign.left,
      );
    }
    SlideVerticalAlign? vAlign;
    if (json['vAlign'] != null) {
      vAlign = SlideVerticalAlign.values.firstWhere(
        (a) => a.name == json['vAlign'],
        orElse: () => SlideVerticalAlign.top,
      );
    }

    return SlideTextStyle(
      color: json['color'] as String?,
      fontSize: json['fontSize'] as int?,
      align: align,
      vAlign: vAlign,
      bold: json['bold'] as bool?,
      italic: json['italic'] as bool?,
    );
  }

  Map<String, dynamic> toJson() => {
    if (color != null) 'color': color,
    if (fontSize != null) 'fontSize': fontSize,
    if (align != null) 'align': align!.name,
    if (vAlign != null) 'vAlign': vAlign!.name,
    if (bold != null) 'bold': bold,
    if (italic != null) 'italic': italic,
  };

  SlideTextStyle copyWith({
    String? color,
    int? fontSize,
    SlideTextAlign? align,
    SlideVerticalAlign? vAlign,
    bool? bold,
    bool? italic,
  }) {
    return SlideTextStyle(
      color: color ?? this.color,
      fontSize: fontSize ?? this.fontSize,
      align: align ?? this.align,
      vAlign: vAlign ?? this.vAlign,
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
    );
  }
}

/// A text span with optional formatting marks
class SlideTextSpan {
  final String value;
  final Set<String> marks;

  SlideTextSpan({
    required this.value,
    Set<String>? marks,
  }) : marks = marks ?? {};

  factory SlideTextSpan.fromJson(Map<String, dynamic> json) {
    final marksJson = json['marks'] as List<dynamic>? ?? [];
    final marks = marksJson.map((m) => m as String).toSet();

    return SlideTextSpan(
      value: json['value'] as String? ?? '',
      marks: marks,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': 'text',
    'value': value,
    if (marks.isNotEmpty) 'marks': marks.toList(),
  };

  bool get isBold => marks.contains('bold');
  bool get isItalic => marks.contains('italic');
  bool get isUnderline => marks.contains('underline');
}

/// A slide element (text or image)
class SlideElement {
  final String id;
  final SlideElementType type;
  final ElementPosition position;
  final List<SlideTextSpan> content;
  final SlideTextStyle? style;
  final String? imagePath; // For image elements

  SlideElement({
    required this.id,
    required this.type,
    required this.position,
    required this.content,
    this.style,
    this.imagePath,
  });

  factory SlideElement.fromJson(Map<String, dynamic> json) {
    final type = SlideElementType.values.firstWhere(
      (t) => t.name == json['type'],
      orElse: () => SlideElementType.text,
    );

    final contentJson = json['content'] as List<dynamic>? ?? [];
    final content = contentJson
        .map((c) => SlideTextSpan.fromJson(c as Map<String, dynamic>))
        .toList();

    SlideTextStyle? style;
    if (json['style'] != null) {
      style = SlideTextStyle.fromJson(json['style'] as Map<String, dynamic>);
    }

    return SlideElement(
      id: json['id'] as String? ?? '',
      type: type,
      position: ElementPosition.fromJson(
        json['position'] as Map<String, dynamic>? ?? {},
      ),
      content: content,
      style: style,
      imagePath: json['imagePath'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'position': position.toJson(),
    'content': content.map((c) => c.toJson()).toList(),
    if (style != null) 'style': style!.toJson(),
    if (imagePath != null) 'imagePath': imagePath,
  };

  /// Get plain text content
  String get plainText => content.map((c) => c.value).join();

  /// Create a text element
  factory SlideElement.text({
    required String id,
    required ElementPosition position,
    String text = '',
    SlideTextStyle? style,
  }) {
    return SlideElement(
      id: id,
      type: SlideElementType.text,
      position: position,
      content: [SlideTextSpan(value: text)],
      style: style,
    );
  }

  /// Create an image element
  factory SlideElement.image({
    required String id,
    required ElementPosition position,
    required String imagePath,
  }) {
    return SlideElement(
      id: id,
      type: SlideElementType.image,
      position: position,
      content: [],
      imagePath: imagePath,
    );
  }

  SlideElement copyWith({
    String? id,
    SlideElementType? type,
    ElementPosition? position,
    List<SlideTextSpan>? content,
    SlideTextStyle? style,
    String? imagePath,
  }) {
    return SlideElement(
      id: id ?? this.id,
      type: type ?? this.type,
      position: position ?? this.position,
      content: content ?? this.content,
      style: style ?? this.style,
      imagePath: imagePath ?? this.imagePath,
    );
  }
}

/// Slide background
class SlideBackground {
  final String type;
  final String? color;
  final String? image;

  SlideBackground({
    this.type = 'solid',
    this.color,
    this.image,
  });

  factory SlideBackground.fromJson(Map<String, dynamic> json) {
    return SlideBackground(
      type: json['type'] as String? ?? 'solid',
      color: json['color'] as String?,
      image: json['image'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    if (color != null) 'color': color,
    if (image != null) 'image': image,
  };

  factory SlideBackground.solid(String color) => SlideBackground(
    type: 'solid',
    color: color,
  );

  factory SlideBackground.white() => SlideBackground.solid('#FFFFFF');
}

/// Individual slide
class PresentationSlide {
  final String id;
  int index;
  SlideLayout layout;
  SlideBackground background;
  List<SlideElement> elements;
  String notes;

  PresentationSlide({
    required this.id,
    required this.index,
    this.layout = SlideLayout.blank,
    SlideBackground? background,
    List<SlideElement>? elements,
    this.notes = '',
  }) : background = background ?? SlideBackground.white(),
       elements = elements ?? [];

  factory PresentationSlide.fromJson(Map<String, dynamic> json) {
    final layout = SlideLayout.values.firstWhere(
      (l) => l.name == json['layout'],
      orElse: () => SlideLayout.blank,
    );

    final elementsJson = json['elements'] as List<dynamic>? ?? [];
    final elements = elementsJson
        .map((e) => SlideElement.fromJson(e as Map<String, dynamic>))
        .toList();

    SlideBackground? background;
    if (json['background'] != null) {
      background = SlideBackground.fromJson(
        json['background'] as Map<String, dynamic>,
      );
    }

    return PresentationSlide(
      id: json['id'] as String? ?? '',
      index: json['index'] as int? ?? 0,
      layout: layout,
      background: background,
      elements: elements,
      notes: json['notes'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'index': index,
    'layout': layout.name,
    'background': background.toJson(),
    'elements': elements.map((e) => e.toJson()).toList(),
    if (notes.isNotEmpty) 'notes': notes,
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Create a blank slide
  factory PresentationSlide.blank({
    required String id,
    required int index,
    String? backgroundColor,
  }) {
    return PresentationSlide(
      id: id,
      index: index,
      layout: SlideLayout.blank,
      background: backgroundColor != null
          ? SlideBackground.solid(backgroundColor)
          : null,
    );
  }

  /// Create a title slide
  factory PresentationSlide.title({
    required String id,
    required int index,
    String title = 'Title',
    String subtitle = '',
    String? backgroundColor,
  }) {
    final elements = <SlideElement>[
      SlideElement.text(
        id: 'title',
        position: ElementPosition.centerTitle(),
        text: title,
        style: SlideTextStyle(
          fontSize: 72,
          bold: true,
          align: SlideTextAlign.center,
        ),
      ),
    ];

    if (subtitle.isNotEmpty) {
      elements.add(SlideElement.text(
        id: 'subtitle',
        position: ElementPosition(x: '10%', y: '60%', w: '80%', h: '15%'),
        text: subtitle,
        style: SlideTextStyle(
          fontSize: 36,
          align: SlideTextAlign.center,
        ),
      ));
    }

    return PresentationSlide(
      id: id,
      index: index,
      layout: SlideLayout.title,
      background: backgroundColor != null
          ? SlideBackground.solid(backgroundColor)
          : null,
      elements: elements,
    );
  }

  /// Create a title + content slide
  factory PresentationSlide.titleContent({
    required String id,
    required int index,
    String title = 'Title',
    String content = '',
    String? backgroundColor,
  }) {
    return PresentationSlide(
      id: id,
      index: index,
      layout: SlideLayout.titleContent,
      background: backgroundColor != null
          ? SlideBackground.solid(backgroundColor)
          : null,
      elements: [
        SlideElement.text(
          id: 'title',
          position: ElementPosition.titleZone(),
          text: title,
          style: SlideTextStyle(
            fontSize: 56,
            bold: true,
          ),
        ),
        SlideElement.text(
          id: 'content',
          position: ElementPosition.contentZone(),
          text: content,
          style: SlideTextStyle(fontSize: 36),
        ),
      ],
    );
  }
}

/// Decoration shape types
enum DecorationShape {
  rectangle,
  circle,
  triangle,
  line,
  gradientBar,
  diagonalStripes,
  dots,
  grid,
  scanlines,
  cornerAccent,
  wave,
}

/// A decorative element on a slide
class SlideDecoration {
  final DecorationShape shape;
  final String x;
  final String y;
  final String w;
  final String h;
  final String color;
  final String? color2; // For gradients
  final double opacity;
  final double? rotation;
  final double? strokeWidth;
  final int? count; // For patterns (stripes, dots, etc.)

  const SlideDecoration({
    required this.shape,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.color,
    this.color2,
    this.opacity = 1.0,
    this.rotation,
    this.strokeWidth,
    this.count,
  });

  double get xPercent => ElementPosition.parsePercent(x);
  double get yPercent => ElementPosition.parsePercent(y);
  double get wPercent => ElementPosition.parsePercent(w);
  double get hPercent => ElementPosition.parsePercent(h);
}

/// Predefined slide template
class SlideTemplate {
  final String id;
  final String nameKey; // i18n key
  final ThemeColors colors;
  final List<SlideDecoration> decorations;
  final String? gradientStart;
  final String? gradientEnd;
  final bool hasGradientBackground;
  final String? titleBarColor;
  final String? titleBarY;
  final String? titleBarH;

  const SlideTemplate({
    required this.id,
    required this.nameKey,
    required this.colors,
    this.decorations = const [],
    this.gradientStart,
    this.gradientEnd,
    this.hasGradientBackground = false,
    this.titleBarColor,
    this.titleBarY,
    this.titleBarH,
  });

  /// Predefined templates with visual decorations
  static const List<SlideTemplate> templates = [
    // Classic - Professional with header bar
    SlideTemplate(
      id: 'classic',
      nameKey: 'work_template_classic',
      colors: ThemeColors(
        primary: '#1E3A5F',
        secondary: '#4A90D9',
        accent: '#F5A623',
        background: '#FFFFFF',
        text: '#1E3A5F',
      ),
      titleBarColor: '#1E3A5F',
      titleBarY: '0%',
      titleBarH: '12%',
      decorations: [
        // Bottom accent line
        SlideDecoration(
          shape: DecorationShape.rectangle,
          x: '0%', y: '95%', w: '100%', h: '5%',
          color: '#4A90D9',
          opacity: 0.8,
        ),
        // Corner accent
        SlideDecoration(
          shape: DecorationShape.cornerAccent,
          x: '90%', y: '0%', w: '10%', h: '12%',
          color: '#F5A623',
          opacity: 1.0,
        ),
      ],
    ),

    // Black & White - Elegant with geometric accents
    SlideTemplate(
      id: 'blackwhite',
      nameKey: 'work_template_blackwhite',
      colors: ThemeColors(
        primary: '#000000',
        secondary: '#444444',
        accent: '#888888',
        background: '#FFFFFF',
        text: '#000000',
      ),
      decorations: [
        // Top bar
        SlideDecoration(
          shape: DecorationShape.rectangle,
          x: '0%', y: '0%', w: '100%', h: '8%',
          color: '#000000',
        ),
        // Bottom bar
        SlideDecoration(
          shape: DecorationShape.rectangle,
          x: '0%', y: '92%', w: '100%', h: '8%',
          color: '#000000',
        ),
        // Left accent line
        SlideDecoration(
          shape: DecorationShape.rectangle,
          x: '3%', y: '12%', w: '0.5%', h: '76%',
          color: '#888888',
          opacity: 0.5,
        ),
      ],
    ),

    // Dark Mode - Modern with gradient accent
    SlideTemplate(
      id: 'dark',
      nameKey: 'work_template_dark',
      colors: ThemeColors(
        primary: '#FFFFFF',
        secondary: '#A0A0A0',
        accent: '#6C5CE7',
        background: '#121212',
        text: '#FFFFFF',
      ),
      hasGradientBackground: true,
      gradientStart: '#121212',
      gradientEnd: '#1E1E2E',
      decorations: [
        // Gradient accent bar at top
        SlideDecoration(
          shape: DecorationShape.gradientBar,
          x: '0%', y: '0%', w: '100%', h: '4%',
          color: '#6C5CE7',
          color2: '#A855F7',
        ),
        // Corner glow
        SlideDecoration(
          shape: DecorationShape.circle,
          x: '85%', y: '-10%', w: '30%', h: '30%',
          color: '#6C5CE7',
          opacity: 0.15,
        ),
        // Bottom subtle line
        SlideDecoration(
          shape: DecorationShape.rectangle,
          x: '5%', y: '94%', w: '90%', h: '0.3%',
          color: '#6C5CE7',
          opacity: 0.5,
        ),
      ],
    ),

    // Cyber / Neon - Grid and glow effects
    SlideTemplate(
      id: 'cyber',
      nameKey: 'work_template_cyber',
      colors: ThemeColors(
        primary: '#00FFFF',
        secondary: '#FF00FF',
        accent: '#00FF00',
        background: '#0A0A1A',
        text: '#00FFFF',
      ),
      decorations: [
        // Grid pattern
        SlideDecoration(
          shape: DecorationShape.grid,
          x: '0%', y: '0%', w: '100%', h: '100%',
          color: '#00FFFF',
          opacity: 0.08,
          count: 20,
        ),
        // Top neon line
        SlideDecoration(
          shape: DecorationShape.gradientBar,
          x: '0%', y: '0%', w: '100%', h: '2%',
          color: '#00FFFF',
          color2: '#FF00FF',
        ),
        // Bottom neon line
        SlideDecoration(
          shape: DecorationShape.gradientBar,
          x: '0%', y: '98%', w: '100%', h: '2%',
          color: '#FF00FF',
          color2: '#00FFFF',
        ),
        // Corner accent
        SlideDecoration(
          shape: DecorationShape.cornerAccent,
          x: '0%', y: '0%', w: '15%', h: '15%',
          color: '#00FFFF',
          opacity: 0.3,
        ),
        // Opposite corner
        SlideDecoration(
          shape: DecorationShape.cornerAccent,
          x: '85%', y: '85%', w: '15%', h: '15%',
          color: '#FF00FF',
          opacity: 0.3,
        ),
      ],
    ),

    // Retro 80s CRT (Amber) - Scanlines and glow
    SlideTemplate(
      id: 'retro80s',
      nameKey: 'work_template_retro80s',
      colors: ThemeColors(
        primary: '#FFB000',
        secondary: '#FF8C00',
        accent: '#FFCC00',
        background: '#1A0F00',
        text: '#FFB000',
      ),
      decorations: [
        // Scanlines
        SlideDecoration(
          shape: DecorationShape.scanlines,
          x: '0%', y: '0%', w: '100%', h: '100%',
          color: '#000000',
          opacity: 0.15,
          count: 100,
        ),
        // CRT vignette (corners)
        SlideDecoration(
          shape: DecorationShape.circle,
          x: '-20%', y: '-20%', w: '40%', h: '40%',
          color: '#000000',
          opacity: 0.4,
        ),
        SlideDecoration(
          shape: DecorationShape.circle,
          x: '80%', y: '-20%', w: '40%', h: '40%',
          color: '#000000',
          opacity: 0.4,
        ),
        SlideDecoration(
          shape: DecorationShape.circle,
          x: '-20%', y: '80%', w: '40%', h: '40%',
          color: '#000000',
          opacity: 0.4,
        ),
        SlideDecoration(
          shape: DecorationShape.circle,
          x: '80%', y: '80%', w: '40%', h: '40%',
          color: '#000000',
          opacity: 0.4,
        ),
        // Glow bar
        SlideDecoration(
          shape: DecorationShape.rectangle,
          x: '5%', y: '8%', w: '90%', h: '3%',
          color: '#FFB000',
          opacity: 0.3,
        ),
      ],
    ),

    // Retro Green CRT
    SlideTemplate(
      id: 'retro_green',
      nameKey: 'work_template_retro_green',
      colors: ThemeColors(
        primary: '#33FF33',
        secondary: '#00CC00',
        accent: '#66FF66',
        background: '#001A00',
        text: '#33FF33',
      ),
      decorations: [
        // Scanlines
        SlideDecoration(
          shape: DecorationShape.scanlines,
          x: '0%', y: '0%', w: '100%', h: '100%',
          color: '#000000',
          opacity: 0.2,
          count: 120,
        ),
        // Phosphor glow top
        SlideDecoration(
          shape: DecorationShape.rectangle,
          x: '0%', y: '0%', w: '100%', h: '15%',
          color: '#33FF33',
          opacity: 0.05,
        ),
        // Terminal prompt line
        SlideDecoration(
          shape: DecorationShape.rectangle,
          x: '3%', y: '90%', w: '50%', h: '0.5%',
          color: '#33FF33',
          opacity: 0.8,
        ),
      ],
    ),

    // Corporate Blue - Professional header
    SlideTemplate(
      id: 'corporate',
      nameKey: 'work_template_corporate',
      colors: ThemeColors(
        primary: '#1A365D',
        secondary: '#2B6CB0',
        accent: '#ED8936',
        background: '#FFFFFF',
        text: '#1A365D',
      ),
      titleBarColor: '#1A365D',
      titleBarY: '0%',
      titleBarH: '15%',
      decorations: [
        // Accent stripe
        SlideDecoration(
          shape: DecorationShape.rectangle,
          x: '0%', y: '15%', w: '100%', h: '1%',
          color: '#ED8936',
        ),
        // Diagonal pattern in corner
        SlideDecoration(
          shape: DecorationShape.diagonalStripes,
          x: '85%', y: '0%', w: '15%', h: '15%',
          color: '#2B6CB0',
          opacity: 0.3,
          count: 5,
        ),
        // Footer line
        SlideDecoration(
          shape: DecorationShape.rectangle,
          x: '5%', y: '92%', w: '90%', h: '0.3%',
          color: '#1A365D',
          opacity: 0.3,
        ),
      ],
    ),

    // Nature Green - Organic curves
    SlideTemplate(
      id: 'nature',
      nameKey: 'work_template_nature',
      colors: ThemeColors(
        primary: '#2E7D32',
        secondary: '#4CAF50',
        accent: '#81C784',
        background: '#F1F8E9',
        text: '#1B5E20',
      ),
      decorations: [
        // Wave at bottom
        SlideDecoration(
          shape: DecorationShape.wave,
          x: '0%', y: '85%', w: '100%', h: '15%',
          color: '#81C784',
          opacity: 0.4,
        ),
        // Top gradient bar
        SlideDecoration(
          shape: DecorationShape.gradientBar,
          x: '0%', y: '0%', w: '100%', h: '8%',
          color: '#2E7D32',
          color2: '#4CAF50',
        ),
        // Leaf accent circles
        SlideDecoration(
          shape: DecorationShape.circle,
          x: '88%', y: '3%', w: '8%', h: '8%',
          color: '#81C784',
          opacity: 0.6,
        ),
        SlideDecoration(
          shape: DecorationShape.circle,
          x: '92%', y: '6%', w: '5%', h: '5%',
          color: '#4CAF50',
          opacity: 0.4,
        ),
      ],
    ),

    // Sunset Warm - Gradient warmth
    SlideTemplate(
      id: 'sunset',
      nameKey: 'work_template_sunset',
      colors: ThemeColors(
        primary: '#E65100',
        secondary: '#FF9800',
        accent: '#FFB74D',
        background: '#FFF8E1',
        text: '#E65100',
      ),
      decorations: [
        // Sunset gradient bar
        SlideDecoration(
          shape: DecorationShape.gradientBar,
          x: '0%', y: '0%', w: '100%', h: '12%',
          color: '#FF5722',
          color2: '#FFC107',
        ),
        // Sun circle
        SlideDecoration(
          shape: DecorationShape.circle,
          x: '82%', y: '-3%', w: '15%', h: '18%',
          color: '#FFB74D',
          opacity: 0.7,
        ),
        // Bottom warm line
        SlideDecoration(
          shape: DecorationShape.gradientBar,
          x: '0%', y: '95%', w: '100%', h: '5%',
          color: '#FF9800',
          color2: '#FFCC80',
          opacity: 0.6,
        ),
      ],
    ),

    // Ocean Blue - Wave patterns
    SlideTemplate(
      id: 'ocean',
      nameKey: 'work_template_ocean',
      colors: ThemeColors(
        primary: '#01579B',
        secondary: '#0288D1',
        accent: '#4FC3F7',
        background: '#E1F5FE',
        text: '#01579B',
      ),
      decorations: [
        // Wave at bottom
        SlideDecoration(
          shape: DecorationShape.wave,
          x: '0%', y: '80%', w: '100%', h: '20%',
          color: '#0288D1',
          opacity: 0.3,
        ),
        // Second wave
        SlideDecoration(
          shape: DecorationShape.wave,
          x: '0%', y: '85%', w: '100%', h: '15%',
          color: '#4FC3F7',
          opacity: 0.4,
        ),
        // Top bar
        SlideDecoration(
          shape: DecorationShape.gradientBar,
          x: '0%', y: '0%', w: '100%', h: '10%',
          color: '#01579B',
          color2: '#0288D1',
        ),
        // Bubble accents
        SlideDecoration(
          shape: DecorationShape.circle,
          x: '5%', y: '75%', w: '3%', h: '4%',
          color: '#4FC3F7',
          opacity: 0.5,
        ),
        SlideDecoration(
          shape: DecorationShape.circle,
          x: '10%', y: '78%', w: '2%', h: '2.5%',
          color: '#81D4FA',
          opacity: 0.4,
        ),
      ],
    ),

    // Purple Elegance - Gradient sophistication
    SlideTemplate(
      id: 'purple',
      nameKey: 'work_template_purple',
      colors: ThemeColors(
        primary: '#4A148C',
        secondary: '#7B1FA2',
        accent: '#CE93D8',
        background: '#F3E5F5',
        text: '#4A148C',
      ),
      decorations: [
        // Elegant gradient header
        SlideDecoration(
          shape: DecorationShape.gradientBar,
          x: '0%', y: '0%', w: '100%', h: '10%',
          color: '#4A148C',
          color2: '#7B1FA2',
        ),
        // Corner flourish
        SlideDecoration(
          shape: DecorationShape.cornerAccent,
          x: '88%', y: '0%', w: '12%', h: '10%',
          color: '#CE93D8',
          opacity: 0.8,
        ),
        // Subtle diagonal pattern
        SlideDecoration(
          shape: DecorationShape.diagonalStripes,
          x: '0%', y: '90%', w: '20%', h: '10%',
          color: '#7B1FA2',
          opacity: 0.1,
          count: 8,
        ),
        // Bottom accent
        SlideDecoration(
          shape: DecorationShape.rectangle,
          x: '0%', y: '95%', w: '100%', h: '5%',
          color: '#7B1FA2',
          opacity: 0.2,
        ),
      ],
    ),

    // Minimalist Gray - Clean subtle accents
    SlideTemplate(
      id: 'minimalist',
      nameKey: 'work_template_minimalist',
      colors: ThemeColors(
        primary: '#37474F',
        secondary: '#607D8B',
        accent: '#90A4AE',
        background: '#FAFAFA',
        text: '#263238',
      ),
      decorations: [
        // Thin top line
        SlideDecoration(
          shape: DecorationShape.rectangle,
          x: '0%', y: '0%', w: '100%', h: '0.5%',
          color: '#37474F',
        ),
        // Left accent bar
        SlideDecoration(
          shape: DecorationShape.rectangle,
          x: '0%', y: '0%', w: '0.8%', h: '100%',
          color: '#607D8B',
          opacity: 0.6,
        ),
        // Dot pattern in corner
        SlideDecoration(
          shape: DecorationShape.dots,
          x: '85%', y: '85%', w: '12%', h: '12%',
          color: '#90A4AE',
          opacity: 0.3,
          count: 4,
        ),
      ],
    ),
  ];

  static SlideTemplate? getById(String id) {
    for (final template in templates) {
      if (template.id == id) return template;
    }
    return null;
  }
}

/// Theme colors for the presentation
class ThemeColors {
  final String primary;
  final String secondary;
  final String accent;
  final String background;
  final String text;

  const ThemeColors({
    this.primary = '#1E3A5F',
    this.secondary = '#4A90D9',
    this.accent = '#F5A623',
    this.background = '#FFFFFF',
    this.text = '#333333',
  });

  factory ThemeColors.fromJson(Map<String, dynamic> json) {
    return ThemeColors(
      primary: json['primary'] as String? ?? '#1E3A5F',
      secondary: json['secondary'] as String? ?? '#4A90D9',
      accent: json['accent'] as String? ?? '#F5A623',
      background: json['background'] as String? ?? '#FFFFFF',
      text: json['text'] as String? ?? '#333333',
    );
  }

  Map<String, dynamic> toJson() => {
    'primary': primary,
    'secondary': secondary,
    'accent': accent,
    'background': background,
    'text': text,
  };
}

/// Theme font definition
class ThemeFont {
  final String family;
  final int weight;

  ThemeFont({
    this.family = 'sans-serif',
    this.weight = 400,
  });

  factory ThemeFont.fromJson(Map<String, dynamic> json) {
    return ThemeFont(
      family: json['family'] as String? ?? 'sans-serif',
      weight: json['weight'] as int? ?? 400,
    );
  }

  Map<String, dynamic> toJson() => {
    'family': family,
    'weight': weight,
  };
}

/// Theme fonts for the presentation
class ThemeFonts {
  final ThemeFont heading;
  final ThemeFont body;

  ThemeFonts({
    ThemeFont? heading,
    ThemeFont? body,
  }) : heading = heading ?? ThemeFont(weight: 700),
       body = body ?? ThemeFont();

  factory ThemeFonts.fromJson(Map<String, dynamic> json) {
    return ThemeFonts(
      heading: json['heading'] != null
          ? ThemeFont.fromJson(json['heading'] as Map<String, dynamic>)
          : null,
      body: json['body'] != null
          ? ThemeFont.fromJson(json['body'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'heading': heading.toJson(),
    'body': body.toJson(),
  };
}

/// Presentation theme
class PresentationTheme {
  final ThemeColors colors;
  final ThemeFonts fonts;

  PresentationTheme({
    ThemeColors? colors,
    ThemeFonts? fonts,
  }) : colors = colors ?? ThemeColors(),
       fonts = fonts ?? ThemeFonts();

  factory PresentationTheme.fromJson(Map<String, dynamic> json) {
    return PresentationTheme(
      colors: json['colors'] != null
          ? ThemeColors.fromJson(json['colors'] as Map<String, dynamic>)
          : null,
      fonts: json['fonts'] != null
          ? ThemeFonts.fromJson(json['fonts'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'colors': colors.toJson(),
    'fonts': fonts.toJson(),
  };
}

/// Slide transition configuration
class SlideTransition {
  final String type;
  final int duration;

  SlideTransition({
    this.type = 'fade',
    this.duration = 300,
  });

  factory SlideTransition.fromJson(Map<String, dynamic> json) {
    return SlideTransition(
      type: json['type'] as String? ?? 'fade',
      duration: json['duration'] as int? ?? 300,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    'duration': duration,
  };
}

/// Main presentation content (main.json)
class PresentationContent {
  final String schema;
  final String aspectRatio;
  final Map<String, int> dimensions;
  final List<String> slides;
  final PresentationTheme theme;
  final SlideTransition defaultTransition;

  PresentationContent({
    this.schema = 'ndf-slides-1.0',
    this.aspectRatio = '16:9',
    Map<String, int>? dimensions,
    required this.slides,
    PresentationTheme? theme,
    SlideTransition? defaultTransition,
  }) : dimensions = dimensions ?? {'width': 1920, 'height': 1080},
       theme = theme ?? PresentationTheme(),
       defaultTransition = defaultTransition ?? SlideTransition();

  factory PresentationContent.create() {
    return PresentationContent(
      slides: ['slide-001'],
    );
  }

  factory PresentationContent.fromJson(Map<String, dynamic> json) {
    final dimensionsJson = json['dimensions'] as Map<String, dynamic>? ?? {};
    final dimensions = <String, int>{
      'width': (dimensionsJson['width'] as num?)?.toInt() ?? 1920,
      'height': (dimensionsJson['height'] as num?)?.toInt() ?? 1080,
    };

    final slidesJson = json['slides'] as List<dynamic>? ?? [];
    final slides = slidesJson.map((s) => s as String).toList();

    PresentationTheme? theme;
    if (json['theme'] != null) {
      theme = PresentationTheme.fromJson(json['theme'] as Map<String, dynamic>);
    }

    SlideTransition? defaultTransition;
    final transitionsJson = json['transitions'] as Map<String, dynamic>?;
    if (transitionsJson != null && transitionsJson['default'] != null) {
      defaultTransition = SlideTransition.fromJson(
        transitionsJson['default'] as Map<String, dynamic>,
      );
    }

    return PresentationContent(
      schema: json['schema'] as String? ?? 'ndf-slides-1.0',
      aspectRatio: json['aspect_ratio'] as String? ?? '16:9',
      dimensions: dimensions,
      slides: slides.isEmpty ? ['slide-001'] : slides,
      theme: theme,
      defaultTransition: defaultTransition,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': 'presentation',
    'schema': schema,
    'aspect_ratio': aspectRatio,
    'dimensions': dimensions,
    'slides': slides,
    'theme': theme.toJson(),
    'transitions': {
      'default': defaultTransition.toJson(),
    },
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Get aspect ratio as double
  double get aspectRatioValue {
    final parts = aspectRatio.split(':');
    if (parts.length == 2) {
      final w = double.tryParse(parts[0]) ?? 16;
      final h = double.tryParse(parts[1]) ?? 9;
      return w / h;
    }
    return 16 / 9;
  }
}
