import 'dart:convert';

import 'frame.dart';

class GeoBlueJsonStreamDecoder {
  final StringBuffer _buffer = StringBuffer();

  List<GeoBlueFrame> addChunk(String chunk) {
    if (chunk.isEmpty) {
      return const <GeoBlueFrame>[];
    }

    _buffer.write(chunk);
    final frames = <GeoBlueFrame>[];

    while (true) {
      final source = _buffer.toString();
      final bounds = _findJsonBounds(source);
      if (bounds == null) {
        break;
      }

      final start = bounds.$1;
      final end = bounds.$2;

      if (start > 0) {
        final prefixTrimmed = source.substring(0, start).trim();
        if (prefixTrimmed.isNotEmpty) {
          // Drop non-JSON prefix noise and continue.
        }
      }

      final jsonText = source.substring(start, end + 1);
      final remaining = source.substring(end + 1);
      _replaceBuffer(remaining);

      try {
        final decoded = jsonDecode(jsonText);
        if (decoded is Map<String, dynamic>) {
          frames.add(GeoBlueFrame.fromJson(decoded));
        }
      } catch (_) {
        // Ignore malformed frame and continue stream parsing.
      }
    }

    return frames;
  }

  void clear() {
    _replaceBuffer('');
  }

  void _replaceBuffer(String content) {
    _buffer
      ..clear()
      ..write(content);
  }

  (int, int)? _findJsonBounds(String data) {
    if (data.isEmpty) {
      return null;
    }

    int start = -1;
    for (var i = 0; i < data.length; i++) {
      if (data.codeUnitAt(i) == 0x7b) {
        start = i;
        break;
      }
    }
    if (start < 0) {
      _replaceBuffer('');
      return null;
    }

    var depth = 0;
    var inString = false;
    var escaped = false;

    for (var i = start; i < data.length; i++) {
      final ch = data.codeUnitAt(i);

      if (escaped) {
        escaped = false;
        continue;
      }

      if (inString && ch == 0x5c) {
        escaped = true;
        continue;
      }

      if (ch == 0x22) {
        inString = !inString;
        continue;
      }

      if (inString) {
        continue;
      }

      if (ch == 0x7b) {
        depth++;
      } else if (ch == 0x7d) {
        depth--;
        if (depth == 0) {
          return (start, i);
        }
      }
    }

    if (start > 0) {
      _replaceBuffer(data.substring(start));
    }
    return null;
  }
}
