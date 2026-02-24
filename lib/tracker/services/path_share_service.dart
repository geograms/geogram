import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/tracker_models.dart';
import '../models/tracker_path_type.dart';
import '../../services/i18n_service.dart';
import '../../services/map_tile_service.dart';
import '../../services/static_map_service.dart';

/// Service for generating and sharing path activity images
class PathShareService {
  // Image dimensions (portrait format for social media)
  static const double _imageWidth = 1080;
  static const double _imageHeight = 1350;

  /// Generate a shareable PNG image of the path activity
  static Future<Uint8List?> generateShareImage({
    required BuildContext context,
    required TrackerPath path,
    required TrackerPathPoints? points,
    required double totalDistanceMeters,
    required Duration duration,
    required double? avgSpeedMps,
    required double? maxSpeedMps,
    required double? elevationDifference,
    required String? startCity,
    required String? endCity,
    required I18nService i18n,
    TrackerExpenses? expenses,
  }) async {
    try {
      final pathType = TrackerPathType.fromTags(path.tags) ?? TrackerPathType.other;
      final pathPoints = points?.points ?? [];

      // Calculate map bounds if we have points
      _MapBounds? bounds;
      if (pathPoints.length >= 2) {
        bounds = _calculateBounds(pathPoints);
      }

      // Determine layout based on content
      final hasExpenses = expenses != null && expenses.expenses.isNotEmpty;
      final hasFuelOrTolls = hasExpenses &&
          (expenses.fuelExpenses.isNotEmpty ||
              expenses.expenses.any((e) => e.type == ExpenseType.toll));

      // Dynamic map height: 75% base, reduce if we have expense breakdown
      final mapHeightRatio = hasFuelOrTolls ? 0.72 : 0.75;

      // Create a picture recorder and canvas
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final size = const Size(_imageWidth, _imageHeight);
      final mapHeight = size.height * mapHeightRatio;

      // Fetch map tiles from cache (same cache used by FlutterMap in path_detail_page.dart)
      ui.Image? mapImage;
      if (bounds != null) {
        mapImage = await _fetchMapTiles(bounds, size.width, mapHeight, totalDistanceMeters);
      }

      // Use the original path bounds for drawing the route
      // This ensures the path is centered (path bounds have symmetric padding)
      // Same approach as FlutterMap's CameraFit.bounds

      // Draw the share image
      _drawShareImage(
        canvas: canvas,
        size: size,
        mapHeight: mapHeight,
        path: path,
        pathType: pathType,
        pathPoints: pathPoints,
        bounds: bounds,
        mapImage: mapImage,
        totalDistanceMeters: totalDistanceMeters,
        duration: duration,
        avgSpeedMps: avgSpeedMps,
        maxSpeedMps: maxSpeedMps,
        elevationDifference: elevationDifference,
        startCity: startCity,
        endCity: endCity,
        expenses: expenses,
        i18n: i18n,
      );

      mapImage?.dispose();

      // Convert to image
      final picture = recorder.endRecording();
      final image = await picture.toImage(_imageWidth.toInt(), _imageHeight.toInt());
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();

      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('PathShareService: Error generating image: $e');
      return null;
    }
  }

  /// Calculate bounds from path points with padding
  static _MapBounds _calculateBounds(List<TrackerPoint> points) {
    double minLat = double.infinity, maxLat = -double.infinity;
    double minLon = double.infinity, maxLon = -double.infinity;

    for (final point in points) {
      minLat = math.min(minLat, point.lat);
      maxLat = math.max(maxLat, point.lat);
      minLon = math.min(minLon, point.lon);
      maxLon = math.max(maxLon, point.lon);
    }

    // Add padding (15%)
    final latPadding = (maxLat - minLat) * 0.15;
    final lonPadding = (maxLon - minLon) * 0.15;
    minLat -= latPadding;
    maxLat += latPadding;
    minLon -= lonPadding;
    maxLon += lonPadding;

    // Ensure minimum bounds
    if (maxLat - minLat < 0.001) {
      minLat -= 0.005;
      maxLat += 0.005;
    }
    if (maxLon - minLon < 0.001) {
      minLon -= 0.005;
      maxLon += 0.005;
    }

    return _MapBounds(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon);
  }

  /// Fetch map tiles from cache and compose them into a single image
  /// Uses the same tile cache as the FlutterMap in path_detail_page.dart
  /// Tiles are positioned such that path bounds maps to the output image
  static Future<ui.Image?> _fetchMapTiles(
    _MapBounds bounds,
    double width,
    double height,
    double totalDistanceMeters,
  ) async {
    try {
      // Get tile cache path from MapTileService
      final mapTileService = MapTileService();
      await mapTileService.initialize();
      final tilesPath = mapTileService.tilesPath;
      if (tilesPath == null) {
        debugPrint('PathShareService: No tiles path available');
        return null;
      }

      final latSpan = bounds.maxLat - bounds.minLat;
      final lonSpan = bounds.maxLon - bounds.minLon;
      final maxSpan = math.max(latSpan, lonSpan);

      // Determine zoom level
      int zoom = 12;
      if (maxSpan > 5) {
        zoom = 6;
      } else if (maxSpan > 2) {
        zoom = 7;
      } else if (maxSpan > 1) {
        zoom = 8;
      } else if (maxSpan > 0.5) {
        zoom = 9;
      } else if (maxSpan > 0.2) {
        zoom = 10;
      } else if (maxSpan > 0.1) {
        zoom = 11;
      } else if (maxSpan > 0.05) {
        zoom = 12;
      } else {
        zoom = 13;
      }

      // Get tiles that cover the bounds (with extra margin)
      final minTileX = _lonToTileX(bounds.minLon, zoom) - 1;
      final maxTileX = _lonToTileX(bounds.maxLon, zoom) + 1;
      final minTileY = _latToTileY(bounds.maxLat, zoom) - 1;
      final maxTileY = _latToTileY(bounds.minLat, zoom) + 1;

      // Load tiles from cache for each layer
      final satelliteTiles = <_TileImage>[];
      final bordersTiles = <_TileImage>[];
      final labelsTiles = <_TileImage>[];
      final transportTiles = <_TileImage>[];

      for (int x = minTileX; x <= maxTileX; x++) {
        for (int y = minTileY; y <= maxTileY; y++) {
          final satBytes = await _readCachedTile(tilesPath, 'satellite', zoom, x, y);
          if (satBytes != null) {
            satelliteTiles.add(_TileImage(x: x, y: y, bytes: satBytes));
          }
          final bordersBytes = await _readCachedTile(tilesPath, 'borders', zoom, x, y);
          if (bordersBytes != null) {
            bordersTiles.add(_TileImage(x: x, y: y, bytes: bordersBytes));
          }
          final labelsBytes = await _readCachedTile(tilesPath, 'labels', zoom, x, y);
          if (labelsBytes != null) {
            labelsTiles.add(_TileImage(x: x, y: y, bytes: labelsBytes));
          }
          if (totalDistanceMeters < 100000) {
            final transportBytes = await _readCachedTile(tilesPath, 'transport', zoom, x, y);
            if (transportBytes != null) {
              transportTiles.add(_TileImage(x: x, y: y, bytes: transportBytes));
            }
          }
        }
      }

      if (satelliteTiles.isEmpty) {
        debugPrint('PathShareService: No satellite tiles in cache');
        return null;
      }

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      // Background
      canvas.drawRect(
        Rect.fromLTWH(0, 0, width, height),
        Paint()..color = const Color(0xFF1a1a2e),
      );

      // Calculate scale: how many pixels per degree
      // We want the path bounds to fill the output image
      final scaleX = width / lonSpan;
      final scaleY = height / latSpan;

      // Convert tile coordinates to screen position
      // Tile (x, y) covers lon [tileXToLon(x), tileXToLon(x+1)] and lat [tileYToLat(y+1), tileYToLat(y)]
      Rect tileToScreen(int tileX, int tileY) {
        final tileLonMin = _tileXToLon(tileX, zoom);
        final tileLonMax = _tileXToLon(tileX + 1, zoom);
        final tileLatMax = _tileYToLat(tileY, zoom);
        final tileLatMin = _tileYToLat(tileY + 1, zoom);

        // Screen coordinates: (0,0) is top-left, path bounds maps to full image
        final screenX = (tileLonMin - bounds.minLon) * scaleX;
        final screenY = (bounds.maxLat - tileLatMax) * scaleY;
        final screenW = (tileLonMax - tileLonMin) * scaleX;
        final screenH = (tileLatMax - tileLatMin) * scaleY;

        return Rect.fromLTWH(screenX, screenY, screenW, screenH);
      }

      // Draw tiles positioned according to path bounds.
      // Keep image handles alive until after toImage() — the recording canvas
      // defers rendering, so early dispose invalidates pixel data.
      final tileImages = <ui.Image>[];
      tileImages.addAll(
          await _drawTileLayerMapped(canvas, satelliteTiles, zoom, tileToScreen, null));
      tileImages.addAll(
          await _drawTileLayerMapped(canvas, bordersTiles, zoom, tileToScreen,
        const ColorFilter.matrix(<double>[
          1.2, 0, 0, 0, 0,
          0, 1.2, 0, 0, 0,
          0, 0, 1.2, 0, 0,
          0, 0, 0, 0.7, 0,
        ])));
      tileImages.addAll(
          await _drawTileLayerMapped(canvas, labelsTiles, zoom, tileToScreen, null));
      if (totalDistanceMeters < 100000) {
        tileImages.addAll(
            await _drawTileLayerMapped(canvas, transportTiles, zoom, tileToScreen,
          const ColorFilter.matrix(<double>[
            0.3, 0.3, 0.3, 0, 30,
            0.3, 0.3, 0.3, 0, 30,
            0.3, 0.3, 0.3, 0, 30,
            0, 0, 0, 1.0, 0,
          ])));
      }

      final picture = recorder.endRecording();
      final result = await picture.toImage(width.toInt(), height.toInt());

      // Now safe to dispose tile images
      for (final img in tileImages) {
        img.dispose();
      }
      return result;
    } catch (e) {
      debugPrint('PathShareService: Error compositing map tiles: $e');
      return null;
    }
  }

  /// Draw tiles using a mapping function from tile coords to screen rect
  /// (delegates to StaticMapService.drawTileLayer).
  /// Returns decoded image handles — caller must dispose after toImage().
  static Future<List<ui.Image>> _drawTileLayerMapped(
    Canvas canvas,
    List<_TileImage> tiles,
    int zoom,
    Rect Function(int tileX, int tileY) tileToScreen,
    ColorFilter? colorFilter,
  ) async {
    final converted = tiles
        .map((t) => TileImage(x: t.x, y: t.y, bytes: t.bytes))
        .toList();
    return StaticMapService.drawTileLayer(
        canvas, converted, tileToScreen, colorFilter);
  }

  /// Read a tile from the cache (delegates to StaticMapService).
  static Future<Uint8List?> _readCachedTile(String tilesPath, String layer, int z, int x, int y) =>
      StaticMapService.readCachedTile(tilesPath, layer, z, x, y);

  // Web Mercator helpers (delegate to StaticMapService)
  static int _lonToTileX(double lon, int zoom) => StaticMapService.lonToTileX(lon, zoom);
  static int _latToTileY(double lat, int zoom) => StaticMapService.latToTileY(lat, zoom);
  static double _tileXToLon(int x, int zoom) => StaticMapService.tileXToLon(x, zoom);
  static double _tileYToLat(int y, int zoom) => StaticMapService.tileYToLat(y, zoom);

  /// Draw the share image on the canvas
  static void _drawShareImage({
    required Canvas canvas,
    required Size size,
    required double mapHeight,
    required TrackerPath path,
    required TrackerPathType pathType,
    required List<TrackerPoint> pathPoints,
    required _MapBounds? bounds,
    required ui.Image? mapImage,
    required double totalDistanceMeters,
    required Duration duration,
    required double? avgSpeedMps,
    required double? maxSpeedMps,
    required double? elevationDifference,
    required String? startCity,
    required String? endCity,
    required TrackerExpenses? expenses,
    required I18nService i18n,
  }) {
    final statsHeight = size.height - mapHeight;

    // Draw gradient background for entire image
    final bgPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(0, size.height),
        [const Color(0xFF1a1a2e), const Color(0xFF16213e), const Color(0xFF0f3460)],
        [0.0, 0.5, 1.0],
      );
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    // Draw satellite image if available
    if (mapImage != null) {
      canvas.drawImageRect(
        mapImage,
        Rect.fromLTWH(0, 0, mapImage.width.toDouble(), mapImage.height.toDouble()),
        Rect.fromLTWH(0, 0, size.width, mapHeight),
        Paint(),
      );

      // Vignette effect
      final vignettePaint = Paint()
        ..shader = ui.Gradient.radial(
          Offset(size.width / 2, mapHeight / 2),
          size.width * 0.8,
          [Colors.transparent, Colors.black.withValues(alpha: 0.3)],
          [0.5, 1.0],
        );
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, mapHeight), vignettePaint);

      // Gradient fade at bottom of map for smooth transition
      final fadeGradient = Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, mapHeight - 80),
          Offset(0, mapHeight),
          [Colors.transparent, Colors.black.withValues(alpha: 0.8)],
        );
      canvas.drawRect(Rect.fromLTWH(0, mapHeight - 80, size.width, 80), fadeGradient);
    }

    // Draw city label at top
    if (startCity != null || endCity != null) {
      _drawCityLabel(canvas, size.width, startCity, endCity);
    }

    // Draw route if we have points
    if (pathPoints.length >= 2 && bounds != null) {
      _drawRoute(canvas, Size(size.width, mapHeight), pathPoints, bounds, maxSpeedMps ?? 10.0);

      // Draw expense markers on map
      if (expenses != null) {
        _drawExpenseMarkers(canvas, Size(size.width, mapHeight), bounds, expenses);
      }
    } else {
      _drawCenteredIcon(
        canvas,
        Offset(size.width / 2, mapHeight / 2),
        Icons.map_outlined,
        120,
        Colors.white.withValues(alpha: 0.2),
      );
    }

    // Draw markers legend at bottom of map
    _drawMarkersLegend(canvas, mapHeight, i18n);

    // Draw stats area
    _drawStatsArea(
      canvas: canvas,
      offset: Offset(0, mapHeight),
      size: Size(size.width, statsHeight),
      path: path,
      pathType: pathType,
      totalDistanceMeters: totalDistanceMeters,
      duration: duration,
      avgSpeedMps: avgSpeedMps,
      maxSpeedMps: maxSpeedMps,
      elevationDifference: elevationDifference,
      expenses: expenses,
      i18n: i18n,
    );
  }

  /// Draw the route with speed coloring
  static void _drawRoute(
    Canvas canvas,
    Size size,
    List<TrackerPoint> points,
    _MapBounds bounds,
    double maxSpeedMps,
  ) {
    Offset toScreen(double lat, double lon) {
      final x = (lon - bounds.minLon) / (bounds.maxLon - bounds.minLon) * size.width;
      final y = (1 - (lat - bounds.minLat) / (bounds.maxLat - bounds.minLat)) * size.height;
      return Offset(x, y);
    }

    // Draw route segments with speed coloring
    for (int i = 1; i < points.length; i++) {
      final p1 = points[i - 1];
      final p2 = points[i];

      final speed = _calculateSpeed(p1, p2);
      final color = _speedColor(speed, maxSpeedMps);

      final start = toScreen(p1.lat, p1.lon);
      final end = toScreen(p2.lat, p2.lon);

      // Outer glow for visibility
      canvas.drawLine(
        start,
        end,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.5)
          ..strokeWidth = 12.0
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke,
      );

      canvas.drawLine(
        start,
        end,
        Paint()
          ..color = color
          ..strokeWidth = 6.0
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke,
      );
    }

    // Draw start marker (green)
    final startPos = toScreen(points.first.lat, points.first.lon);
    _drawMarker(canvas, startPos, Colors.green);

    // Draw end marker (red)
    if (points.length > 1) {
      final endPos = toScreen(points.last.lat, points.last.lon);
      _drawMarker(canvas, endPos, Colors.red);
    }
  }

  /// Draw expense markers on the map
  static void _drawExpenseMarkers(
    Canvas canvas,
    Size size,
    _MapBounds bounds,
    TrackerExpenses expenses,
  ) {
    Offset toScreen(double lat, double lon) {
      final x = (lon - bounds.minLon) / (bounds.maxLon - bounds.minLon) * size.width;
      final y = (1 - (lat - bounds.minLat) / (bounds.maxLat - bounds.minLat)) * size.height;
      return Offset(x, y);
    }

    for (final expense in expenses.expenses) {
      if (expense.lat == null || expense.lon == null) continue;

      final pos = toScreen(expense.lat!, expense.lon!);
      final color = _getExpenseColor(expense.type);
      final icon = _getExpenseIcon(expense.type);

      // Shadow
      canvas.drawCircle(pos, 18, Paint()..color = Colors.black.withValues(alpha: 0.5));

      // Background circle
      canvas.drawCircle(pos, 16, Paint()..color = color);

      // Icon
      _drawCenteredIcon(canvas, pos, icon, 18, Colors.white);
    }
  }

  static void _drawMarker(Canvas canvas, Offset position, Color color) {
    canvas.drawCircle(position, 18, Paint()..color = Colors.black.withValues(alpha: 0.5));
    canvas.drawCircle(position, 16, Paint()..color = color.withValues(alpha: 0.4));
    canvas.drawCircle(position, 12, Paint()..color = color);
    canvas.drawCircle(position, 4, Paint()..color = Colors.white);
  }

  static void _drawCityLabel(Canvas canvas, double width, String? startCity, String? endCity) {
    String label;
    if (startCity != null && endCity != null && startCity != endCity) {
      label = '$startCity  →  $endCity';
    } else if (startCity != null) {
      label = startCity;
    } else if (endCity != null) {
      label = endCity;
    } else {
      return;
    }

    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 28,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          shadows: [Shadow(color: Colors.black, blurRadius: 8), Shadow(color: Colors.black, blurRadius: 4)],
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: width - 80);

    final bgRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(width / 2, 50),
        width: textPainter.width + 40,
        height: textPainter.height + 20,
      ),
      const Radius.circular(25),
    );

    canvas.drawRRect(bgRect, Paint()..color = Colors.black.withValues(alpha: 0.7));
    canvas.drawRRect(
      bgRect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    textPainter.paint(canvas, Offset((width - textPainter.width) / 2, 50 - textPainter.height / 2));
  }

  static void _drawMarkersLegend(Canvas canvas, double mapHeight, I18nService i18n) {
    final startText = i18n.t('tracker_started');
    final endText = i18n.t('tracker_ended');

    final style = TextStyle(
      color: Colors.white.withValues(alpha: 0.95),
      fontSize: 16,
      fontWeight: FontWeight.w500,
      shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
    );

    final startPainter = TextPainter(
      text: TextSpan(text: startText, style: style),
      textDirection: ui.TextDirection.ltr,
    )..layout();

    final endPainter = TextPainter(
      text: TextSpan(text: endText, style: style),
      textDirection: ui.TextDirection.ltr,
    )..layout();

    final totalWidth = 12 + 8 + startPainter.width + 20 + 12 + 8 + endPainter.width;
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(20, mapHeight - 45, totalWidth + 24, 35),
      const Radius.circular(18),
    );

    canvas.drawRRect(bgRect, Paint()..color = Colors.black.withValues(alpha: 0.6));

    double x = 32;
    final y = mapHeight - 27;

    canvas.drawCircle(Offset(x + 6, y), 6, Paint()..color = Colors.green);
    x += 20;
    startPainter.paint(canvas, Offset(x, y - startPainter.height / 2));
    x += startPainter.width + 20;

    canvas.drawCircle(Offset(x + 6, y), 6, Paint()..color = Colors.red);
    x += 20;
    endPainter.paint(canvas, Offset(x, y - endPainter.height / 2));
  }

  static void _drawStatsArea({
    required Canvas canvas,
    required Offset offset,
    required Size size,
    required TrackerPath path,
    required TrackerPathType pathType,
    required double totalDistanceMeters,
    required Duration duration,
    required double? avgSpeedMps,
    required double? maxSpeedMps,
    required double? elevationDifference,
    required TrackerExpenses? expenses,
    required I18nService i18n,
  }) {
    // Stats background
    final bgPaint = Paint()
      ..shader = ui.Gradient.linear(
        offset,
        Offset(offset.dx, offset.dy + size.height),
        [Colors.black.withValues(alpha: 0.9), Colors.black.withValues(alpha: 0.95)],
      );
    canvas.drawRect(Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height), bgPaint);

    final activityColor = _getActivityColor(pathType);
    double y = offset.dy + 24;
    const margin = 28.0;

    // Activity header row
    final iconBgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(margin, y, 50, 50),
      const Radius.circular(12),
    );
    canvas.drawRRect(iconBgRect, Paint()..color = activityColor.withValues(alpha: 0.2));
    canvas.drawRRect(
      iconBgRect,
      Paint()
        ..color = activityColor.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    _drawCenteredIcon(canvas, Offset(margin + 25, y + 25), pathType.icon, 30, activityColor);

    // Activity name
    final typePainter = TextPainter(
      text: TextSpan(
        text: i18n.t(pathType.translationKey),
        style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: size.width - 120);
    typePainter.paint(canvas, Offset(margin + 60, y + 2));

    // Date range (ISO format)
    final dateStr = _formatDateRange(path.startedAtDateTime, path.endedAtDateTime);
    final datePainter = TextPainter(
      text: TextSpan(
        text: dateStr,
        style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 15),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: size.width - 120);
    datePainter.paint(canvas, Offset(margin + 60, y + 32));

    y += 70;

    // Metric cards grid (3 columns, 2 rows)
    final cardWidth = (size.width - margin * 2 - 16) / 3;
    const cardHeight = 70.0;
    const gap = 8.0;

    // Row 1: Distance, Duration, Avg Speed
    _drawMetricCard(
      canvas,
      Rect.fromLTWH(margin, y, cardWidth, cardHeight),
      Icons.straighten,
      _formatDistance(totalDistanceMeters),
      i18n.t('tracker_distance'),
    );
    _drawMetricCard(
      canvas,
      Rect.fromLTWH(margin + cardWidth + gap, y, cardWidth, cardHeight),
      Icons.timer_outlined,
      _formatDuration(duration),
      i18n.t('tracker_duration'),
    );
    _drawMetricCard(
      canvas,
      Rect.fromLTWH(margin + (cardWidth + gap) * 2, y, cardWidth, cardHeight),
      Icons.speed,
      avgSpeedMps != null ? '${(avgSpeedMps * 3.6).toStringAsFixed(1)} km/h' : '-',
      i18n.t('tracker_avg_speed'),
    );

    y += cardHeight + gap;

    // Row 2: Max Speed, Elevation (if > 50m), Expenses
    _drawMetricCard(
      canvas,
      Rect.fromLTWH(margin, y, cardWidth, cardHeight),
      Icons.speed,
      maxSpeedMps != null ? '${(maxSpeedMps * 3.6).toStringAsFixed(1)} km/h' : '-',
      i18n.t('tracker_max_speed'),
    );

    // Only show elevation if meaningful (> 50m difference)
    final showElevation = elevationDifference != null && elevationDifference.abs() > 50;
    if (showElevation) {
      final elevIcon = elevationDifference! >= 0 ? Icons.trending_up : Icons.trending_down;
      final elevStr = elevationDifference >= 0
          ? '+${elevationDifference.toStringAsFixed(0)} m'
          : '${elevationDifference.toStringAsFixed(0)} m';
      _drawMetricCard(
        canvas,
        Rect.fromLTWH(margin + cardWidth + gap, y, cardWidth, cardHeight),
        elevIcon,
        elevStr,
        i18n.t('tracker_elevation_difference'),
      );
    }

    // Expenses total
    final hasExpenses = expenses != null && expenses.expenses.isNotEmpty;
    if (hasExpenses) {
      final totalCost = expenses!.totalAllCost;
      final currency = expenses.commonCurrency ?? 'EUR';
      final symbol = _getCurrencySymbol(currency);

      _drawMetricCard(
        canvas,
        Rect.fromLTWH(margin + (cardWidth + gap) * 2, y, cardWidth, cardHeight),
        Icons.receipt_long,
        '$symbol${totalCost.toStringAsFixed(2)}',
        i18n.t('tracker_expenses'),
      );
    }

    y += cardHeight + 12;

    // Expense breakdown row (fuel/tolls as pills)
    if (hasExpenses) {
      final fuelTotal = expenses!.fuelExpenses.fold(0.0, (sum, e) => sum + e.amount);
      final tollTotal = expenses.expenses
          .where((e) => e.type == ExpenseType.toll)
          .fold(0.0, (sum, e) => sum + e.amount);
      final currency = expenses.commonCurrency ?? 'EUR';
      final symbol = _getCurrencySymbol(currency);

      double pillX = margin;

      if (fuelTotal > 0) {
        pillX = _drawExpensePill(
          canvas,
          Offset(pillX, y),
          Icons.local_gas_station,
          '$symbol${fuelTotal.toStringAsFixed(2)}',
          i18n.t('tracker_expense_fuel'),
          Colors.orange,
        );
        pillX += 16;
      }

      if (tollTotal > 0) {
        _drawExpensePill(
          canvas,
          Offset(pillX, y),
          Icons.toll,
          '$symbol${tollTotal.toStringAsFixed(2)}',
          i18n.t('tracker_expense_toll'),
          Colors.blue,
        );
      }

      if (fuelTotal > 0 || tollTotal > 0) {
        y += 40;
      }
    }

    // Branding footer
    final brandingPainter = TextPainter(
      text: TextSpan(
        text: '─── ${i18n.t('tracker_tracked_with')} ───',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.35),
          fontSize: 16,
          fontWeight: FontWeight.w300,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    brandingPainter.paint(
      canvas,
      Offset((size.width - brandingPainter.width) / 2, offset.dy + size.height - 35),
    );
  }

  /// Draw a metric card with icon, value, and label
  static void _drawMetricCard(
    Canvas canvas,
    Rect rect,
    IconData icon,
    String value,
    String label,
  ) {
    // Card background
    final cardRect = RRect.fromRectAndRadius(rect, const Radius.circular(12));
    canvas.drawRRect(cardRect, Paint()..color = Colors.white.withValues(alpha: 0.08));
    canvas.drawRRect(
      cardRect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // Value (large, bold)
    final valuePainter = TextPainter(
      text: TextSpan(
        text: value,
        style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: rect.width - 16);
    valuePainter.paint(canvas, Offset(rect.left + 12, rect.top + 12));

    // Label (smaller, muted)
    final labelPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: rect.width - 16);
    labelPainter.paint(canvas, Offset(rect.left + 12, rect.top + 38));

    // Icon in top-right corner
    _drawCenteredIcon(
      canvas,
      Offset(rect.right - 20, rect.top + 20),
      icon,
      20,
      Colors.white.withValues(alpha: 0.3),
    );
  }

  /// Draw an expense pill/badge
  static double _drawExpensePill(
    Canvas canvas,
    Offset offset,
    IconData icon,
    String amount,
    String label,
    Color color,
  ) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: '$amount  $label',
        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();

    final pillWidth = 24 + textPainter.width + 16;
    final pillRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(offset.dx, offset.dy, pillWidth, 32),
      const Radius.circular(16),
    );

    canvas.drawRRect(pillRect, Paint()..color = color.withValues(alpha: 0.2));
    canvas.drawRRect(
      pillRect,
      Paint()
        ..color = color.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    _drawCenteredIcon(canvas, Offset(offset.dx + 16, offset.dy + 16), icon, 16, color);
    textPainter.paint(canvas, Offset(offset.dx + 28, offset.dy + 8));

    return offset.dx + pillWidth;
  }

  /// Format date range with ISO style (YYYY-MM-DD)
  static String _formatDateRange(DateTime start, DateTime? end) {
    if (end == null) {
      return '${DateFormat('yyyy-MM-dd').format(start)} • ${DateFormat.Hm().format(start)} - ...';
    }

    final sameDay = start.year == end.year && start.month == end.month && start.day == end.day;

    if (sameDay) {
      return '${DateFormat('yyyy-MM-dd').format(start)} • ${DateFormat.Hm().format(start)} - ${DateFormat.Hm().format(end)}';
    }

    return '${DateFormat('yyyy-MM-dd HH:mm').format(start)} → ${DateFormat('yyyy-MM-dd HH:mm').format(end)}';
  }

  static void _drawCenteredIcon(Canvas canvas, Offset center, IconData icon, double size, Color color) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(fontSize: size, fontFamily: icon.fontFamily, package: icon.fontPackage, color: color),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    textPainter.paint(canvas, Offset(center.dx - textPainter.width / 2, center.dy - textPainter.height / 2));
  }

  static double _calculateSpeed(TrackerPoint p1, TrackerPoint p2) {
    if (p2.speed != null && p2.speed! > 0) return p2.speed!;
    final distance = _haversineDistance(p1.lat, p1.lon, p2.lat, p2.lon);
    final seconds = p2.timestampDateTime.difference(p1.timestampDateTime).inMilliseconds / 1000.0;
    if (seconds <= 0) return 0;
    return distance / seconds;
  }

  static double _haversineDistance(double lat1, double lon1, double lat2, double lon2) {
    const earthRadiusMeters = 6371000.0;
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) * math.cos(_toRadians(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  static double _toRadians(double degrees) => degrees * math.pi / 180;

  static Color _speedColor(double speed, double maxSpeed) {
    if (maxSpeed <= 0) return Colors.blue;
    final ratio = (speed / maxSpeed).clamp(0.0, 1.0);
    if (ratio <= 0.5) return Color.lerp(Colors.blue, Colors.green, ratio / 0.5) ?? Colors.blue;
    return Color.lerp(Colors.green, Colors.red, (ratio - 0.5) / 0.5) ?? Colors.red;
  }

  static Color _getActivityColor(TrackerPathType type) {
    return switch (type) {
      TrackerPathType.walk => Colors.green,
      TrackerPathType.run => Colors.orange,
      TrackerPathType.bicycle => Colors.lightBlue,
      TrackerPathType.car => Colors.blue,
      TrackerPathType.truck => Colors.blueGrey,
      TrackerPathType.train => Colors.purple,
      TrackerPathType.airplane => Colors.indigo,
      TrackerPathType.hike => Colors.teal,
      TrackerPathType.boat => Colors.cyan,
      TrackerPathType.bus => Colors.amber,
      TrackerPathType.taxi => Colors.yellow,
      TrackerPathType.motorbike => Colors.deepOrange,
      TrackerPathType.travel => Colors.pink,
      TrackerPathType.horse => Colors.brown,
      _ => Colors.grey,
    };
  }

  static IconData _getExpenseIcon(ExpenseType type) {
    return switch (type) {
      ExpenseType.fuel => Icons.local_gas_station,
      ExpenseType.toll => Icons.toll,
      ExpenseType.food => Icons.restaurant,
      ExpenseType.drink => Icons.local_cafe,
      ExpenseType.sleep => Icons.hotel,
      ExpenseType.ticket => Icons.confirmation_number,
      ExpenseType.fine => Icons.gavel,
    };
  }

  static Color _getExpenseColor(ExpenseType type) {
    return switch (type) {
      ExpenseType.fuel => Colors.orange,
      ExpenseType.toll => Colors.blue,
      ExpenseType.food => Colors.green,
      ExpenseType.drink => Colors.brown,
      ExpenseType.sleep => Colors.purple,
      ExpenseType.ticket => Colors.teal,
      ExpenseType.fine => Colors.red,
    };
  }

  static String _formatDistance(double meters) {
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)} km';
    return '${meters.toStringAsFixed(0)} m';
  }

  static String _formatDuration(Duration d) {
    if (d.inDays > 0) {
      final days = d.inDays;
      final hours = d.inHours.remainder(24);
      return '${days}d ${hours}h';
    }
    if (d.inHours > 0) {
      final hours = d.inHours;
      final minutes = d.inMinutes.remainder(60);
      return '${hours}h ${minutes}m';
    }
    if (d.inMinutes > 0) return '${d.inMinutes}m';
    return '${d.inSeconds}s';
  }

  static String _getCurrencySymbol(String currency) {
    return switch (currency) {
      'EUR' => '€',
      'USD' => '\$',
      'GBP' => '£',
      'JPY' => '¥',
      'CHF' => 'CHF ',
      'CAD' => 'CA\$',
      'AUD' => 'A\$',
      'CNY' => '¥',
      'INR' => '₹',
      'BRL' => 'R\$',
      _ => '$currency ',
    };
  }

  /// Share the image using native share sheet or clipboard
  static Future<bool> shareImage(
    Uint8List imageBytes, {
    String? text,
    required BuildContext context,
    required I18nService i18n,
  }) async {
    try {
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
        final tempDir = await getTemporaryDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final file = File('${tempDir.path}/geogram_activity_$timestamp.png');
        await file.writeAsBytes(imageBytes);

        await Share.shareXFiles([XFile(file.path)], text: text);

        Future.delayed(const Duration(minutes: 5), () {
          if (file.existsSync()) file.deleteSync();
        });

        return true;
      } else {
        return await _saveToDownloads(imageBytes, context, i18n);
      }
    } catch (e) {
      debugPrint('PathShareService: Error sharing image: $e');
      return false;
    }
  }

  static Future<bool> _saveToDownloads(Uint8List imageBytes, BuildContext context, I18nService i18n) async {
    try {
      if (kIsWeb) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(i18n.t('tracker_share_not_supported'))),
          );
        }
        return false;
      }

      final Directory downloadDir;
      if (Platform.isWindows || Platform.isLinux) {
        final homeDir = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
        downloadDir = Directory('$homeDir/Downloads');
        if (!downloadDir.existsSync()) downloadDir.createSync(recursive: true);
      } else {
        downloadDir = await getApplicationDocumentsDirectory();
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${downloadDir.path}/geogram_activity_$timestamp.png');
      await file.writeAsBytes(imageBytes);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${i18n.t('tracker_share_saved')}: ${file.path}'),
            duration: const Duration(seconds: 4),
          ),
        );
      }

      return true;
    } catch (e) {
      debugPrint('PathShareService: Error saving to downloads: $e');
      return false;
    }
  }
}

class _MapBounds {
  final double minLat, maxLat, minLon, maxLon;
  _MapBounds({required this.minLat, required this.maxLat, required this.minLon, required this.maxLon});
}

class _TileImage {
  final int x, y;
  final Uint8List bytes;
  _TileImage({required this.x, required this.y, required this.bytes});
}
