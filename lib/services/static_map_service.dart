/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Reusable static map image generation from cached map tiles.
 * Composes satellite + label tiles into a single PNG image centered
 * on given coordinates. Uses the MapTileService tile cache.
 */

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'map_tile_service.dart';

/// Tile image with grid coordinates.
class TileImage {
  final int x, y;
  final Uint8List bytes;
  TileImage({required this.x, required this.y, required this.bytes});
}

/// Generates static map images (PNG bytes) for given coordinates
/// by composing cached satellite/map tiles. Uses Esri World Imagery
/// (satellite) with optional label overlays and a center pin marker.
class StaticMapService {
  // ───── Web Mercator math (public for reuse) ─────

  static int lonToTileX(double lon, int zoom) =>
      ((lon + 180) / 360 * (1 << zoom)).floor();

  static int latToTileY(double lat, int zoom) {
    final latRad = lat * math.pi / 180;
    return ((1 - math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
            2 *
            (1 << zoom))
        .floor();
  }

  static double tileXToLon(int x, int zoom) =>
      x / (1 << zoom) * 360 - 180;

  static double tileYToLat(int y, int zoom) {
    final n = math.pi - 2 * math.pi * y / (1 << zoom);
    return 180 / math.pi * math.atan(0.5 * (math.exp(n) - math.exp(-n)));
  }

  // ───── Tile cache I/O ─────

  /// Read a tile from the file cache. Returns null if not cached.
  static Future<Uint8List?> readCachedTile(
      String tilesPath, String layer, int z, int x, int y) async {
    try {
      final cachePath = '$tilesPath/cache/$layer/$z/$x/$y.png';
      final file = File(cachePath);
      if (await file.exists()) {
        return await file.readAsBytes();
      }
    } catch (_) {}
    return null;
  }

  /// Try reading a tile from cache; if missing, download from Esri and cache it.
  static Future<Uint8List?> _fetchTileWithFallback(
    String tilesPath,
    String layer,
    int z,
    int x,
    int y,
    http.Client httpClient,
  ) async {
    // 1. Try cache
    final cached = await readCachedTile(tilesPath, layer, z, x, y);
    if (cached != null) return cached;

    // 2. Download from Esri
    String url;
    switch (layer) {
      case 'satellite':
        url = MapTileService.satelliteTileUrl
            .replaceAll('{z}', '$z')
            .replaceAll('{y}', '$y')
            .replaceAll('{x}', '$x');
        break;
      case 'labels':
        url = MapTileService.labelsOnlyUrl
            .replaceAll('{z}', '$z')
            .replaceAll('{y}', '$y')
            .replaceAll('{x}', '$x');
        break;
      default:
        return null;
    }

    try {
      final response = await httpClient
          .get(Uri.parse(url), headers: {'User-Agent': 'dev.geogram'})
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200 && response.bodyBytes.length > 100) {
        // Cache to disk
        final cachePath = '$tilesPath/cache/$layer/$z/$x/$y.png';
        final file = File(cachePath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(response.bodyBytes);
        return response.bodyBytes;
      }
    } catch (_) {}
    return null;
  }

  // ───── Canvas tile drawing ─────

  /// Draw a list of tile images onto a canvas, mapping tile coords to screen
  /// rects via [tileToScreen]. Returns decoded [ui.Image] handles that the
  /// caller MUST dispose after [PictureRecorder.endRecording] + [toImage] —
  /// disposing earlier invalidates pixel data since the recording canvas
  /// defers actual rendering.
  static Future<List<ui.Image>> drawTileLayer(
    Canvas canvas,
    List<TileImage> tiles,
    Rect Function(int tileX, int tileY) tileToScreen,
    ColorFilter? colorFilter,
  ) async {
    // Step 1: Pre-decode all tiles to ui.Image (async)
    final decoded = <(TileImage, ui.Image)>[];
    for (final tile in tiles) {
      try {
        final codec = await ui.instantiateImageCodec(tile.bytes);
        final frame = await codec.getNextFrame();
        decoded.add((tile, frame.image));
      } catch (e) {
        debugPrint('StaticMapService: Failed to decode tile ${tile.x},${tile.y}: $e');
      }
    }

    // Step 2: Draw all pre-decoded images onto Canvas (synchronous)
    final paint = Paint();
    if (colorFilter != null) {
      paint.colorFilter = colorFilter;
    }
    final images = <ui.Image>[];
    for (final (tile, image) in decoded) {
      final destRect = tileToScreen(tile.x, tile.y);
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        destRect,
        paint,
      );
      images.add(image);
    }
    return images;
  }

  // ───── Main public API ─────

  /// Generate a static map image centered on [lat], [lon].
  /// Returns PNG bytes or null if tiles unavailable.
  ///
  /// Uses the `image` package (pure Dart) for compositing to reliably
  /// decode both JPEG satellite tiles and PNG label tiles without
  /// Flutter engine async/dispose issues.
  static Future<Uint8List?> generateStaticMap({
    required double lat,
    required double lon,
    int width = 300,
    int height = 200,
    int zoom = 15,
    bool withLabels = true,
    bool withPin = true,
  }) async {
    try {
      final mapTileService = MapTileService();
      await mapTileService.initialize();
      final tilesPath = mapTileService.tilesPath;
      if (tilesPath == null) return null;

      final httpClient = mapTileService.httpClient;

      // Center tile coordinates
      final centerTileX = lonToTileX(lon, zoom);
      final centerTileY = latToTileY(lat, zoom);

      // How many tiles needed to cover width x height (each tile = 256px)
      final tilesW = (width / 256).ceil() + 1;
      final tilesH = (height / 256).ceil() + 1;
      final halfW = tilesW ~/ 2 + 1;
      final halfH = tilesH ~/ 2 + 1;

      final minTileX = centerTileX - halfW;
      final maxTileX = centerTileX + halfW;
      final minTileY = centerTileY - halfH;
      final maxTileY = centerTileY + halfH;

      // Fractional pixel offset: where exactly the center lat/lon falls
      // within its tile (for sub-tile centering)
      final n = 1 << zoom;
      final exactTileX = (lon + 180) / 360 * n;
      final latRad = lat * math.pi / 180;
      final exactTileY =
          (1 - math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
              2 *
              n;
      // Pixel offset of the center within the center tile
      final centerPixelX = (exactTileX - centerTileX) * 256;
      final centerPixelY = (exactTileY - centerTileY) * 256;

      // Fetch satellite tiles
      final satelliteTiles = <TileImage>[];
      final labelsTiles = <TileImage>[];

      for (int x = minTileX; x <= maxTileX; x++) {
        for (int y = minTileY; y <= maxTileY; y++) {
          final satBytes = await _fetchTileWithFallback(
              tilesPath, 'satellite', zoom, x, y, httpClient);
          if (satBytes != null) {
            satelliteTiles.add(TileImage(x: x, y: y, bytes: satBytes));
          }
          if (withLabels) {
            final labelsBytes = await _fetchTileWithFallback(
                tilesPath, 'labels', zoom, x, y, httpClient);
            if (labelsBytes != null) {
              labelsTiles.add(TileImage(x: x, y: y, bytes: labelsBytes));
            }
          }
        }
      }

      if (satelliteTiles.isEmpty) return null;

      // Compose image using the `image` package (pure Dart, no dart:ui)
      final canvas = img.Image(width: width, height: height);

      // Dark background
      img.fill(canvas, color: img.ColorRgba8(0x1a, 0x1a, 0x2e, 0xFF));

      // Map tile (x,y) to screen pixel offset centered on the target lat/lon
      (int dx, int dy) tileToPixel(int tileX, int tileY) {
        final dx = ((tileX - centerTileX) * 256.0 - centerPixelX + width / 2).round();
        final dy = ((tileY - centerTileY) * 256.0 - centerPixelY + height / 2).round();
        return (dx, dy);
      }

      // Draw satellite tiles
      _composeTileLayer(canvas, satelliteTiles, tileToPixel);
      // Draw label tiles (alpha composited over satellite)
      if (withLabels && labelsTiles.isNotEmpty) {
        _composeTileLayer(canvas, labelsTiles, tileToPixel);
      }

      // Draw pin marker at center
      if (withPin) {
        _drawPinImg(canvas, width ~/ 2, height ~/ 2);
      }

      final pngBytes = Uint8List.fromList(img.encodePng(canvas));
      return pngBytes;
    } catch (e) {
      debugPrint('StaticMapService: Error generating static map: $e');
      return null;
    }
  }

  /// Composite a layer of tiles onto the canvas using the `image` package.
  static void _composeTileLayer(
    img.Image canvas,
    List<TileImage> tiles,
    (int, int) Function(int tileX, int tileY) tileToPixel,
  ) {
    for (final tile in tiles) {
      try {
        final decoded = img.decodeImage(tile.bytes);
        if (decoded == null) continue;
        final (dx, dy) = tileToPixel(tile.x, tile.y);
        img.compositeImage(canvas, decoded, dstX: dx, dstY: dy);
      } catch (e) {
        debugPrint('StaticMapService: Failed to decode tile ${tile.x},${tile.y}: $e');
      }
    }
  }

  /// Draw a simple location pin at the given canvas position (image package).
  static void _drawPinImg(img.Image canvas, int cx, int cy) {
    // Red filled circle (radius 8)
    img.fillCircle(canvas, x: cx, y: cy, radius: 8,
        color: img.ColorRgba8(0xE5, 0x39, 0x35, 0xFF));
    // White border ring (draw circle outline by filling r=9 white then r=7 red)
    img.drawCircle(canvas, x: cx, y: cy, radius: 9,
        color: img.ColorRgba8(0xFF, 0xFF, 0xFF, 0xFF));
    img.drawCircle(canvas, x: cx, y: cy, radius: 10,
        color: img.ColorRgba8(0xFF, 0xFF, 0xFF, 0xFF));
    // Inner white dot
    img.fillCircle(canvas, x: cx, y: cy, radius: 3,
        color: img.ColorRgba8(0xFF, 0xFF, 0xFF, 0xFF));
  }

  /// Draw a simple location pin at the given Canvas position (dart:ui).
  /// Used by PathShareService which composites via PictureRecorder.
  static void drawPinOnCanvas(Canvas flutterCanvas, double cx, double cy) {
    // Drop shadow
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.4)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    flutterCanvas.drawCircle(Offset(cx + 1, cy + 1), 8, shadowPaint);

    // Outer red circle
    final outerPaint = Paint()..color = const Color(0xFFE53935);
    flutterCanvas.drawCircle(Offset(cx, cy), 8, outerPaint);

    // White border
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    flutterCanvas.drawCircle(Offset(cx, cy), 8, borderPaint);

    // Inner dot
    final innerPaint = Paint()..color = Colors.white;
    flutterCanvas.drawCircle(Offset(cx, cy), 3, innerPaint);
  }
}
