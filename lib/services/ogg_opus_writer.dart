/*
 * OGG container writer for Opus audio.
 * Creates standard Ogg Opus files that are playable everywhere.
 */

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'log_service.dart';

/// Writes Opus audio packets to an OGG container file.
/// Follows RFC 7845 (Ogg Encapsulation for the Opus Audio Codec).
class OggOpusWriter {
  final File _file;
  final int sampleRate;
  final int channels;
  final int preSkip;

  late RandomAccessFile _raf;
  int _serialNumber = 0;
  int _pageSequence = 0;
  int _granulePosition = 0;

  bool _headerWritten = false;

  /// Create an OGG Opus writer.
  /// [filePath]: Output file path (should end in .ogg)
  /// [sampleRate]: Original sample rate (for OpusHead)
  /// [channels]: Number of audio channels (1 or 2)
  /// [preSkip]: Encoder pre-skip in samples (typically 312 for 16kHz)
  OggOpusWriter(
    String filePath, {
    this.sampleRate = 16000,
    this.channels = 1,
    this.preSkip = 312,
  }) : _file = File(filePath);

  /// Open the file for writing.
  Future<void> open() async {
    _raf = await _file.open(mode: FileMode.write);
    _serialNumber = Random().nextInt(0x7FFFFFFF);
    _pageSequence = 0;
    _granulePosition = 0;
    _headerWritten = false;
  }

  /// Write the OGG headers (OpusHead and OpusTags).
  /// Must be called before writing audio packets.
  Future<void> writeHeaders() async {
    if (_headerWritten) return;

    // Write OpusHead packet (BOS page)
    final opusHead = _buildOpusHead();
    await _writePage(opusHead, headerType: 0x02, granulePosition: 0); // BOS flag

    // Write OpusTags packet
    final opusTags = _buildOpusTags();
    await _writePage(opusTags, headerType: 0x00, granulePosition: 0);

    _headerWritten = true;
    LogService().log('OggOpusWriter: Headers written');
  }

  /// Write Opus audio packets.
  /// [packets]: List of encoded Opus packets
  /// [samplesPerPacket]: Number of PCM samples per packet (e.g., 320 for 20ms at 16kHz)
  Future<void> writePackets(List<Uint8List> packets, int samplesPerPacket) async {
    if (!_headerWritten) {
      await writeHeaders();
    }

    // Write packets, potentially grouping into pages
    // For simplicity, write each packet as its own page
    for (var i = 0; i < packets.length; i++) {
      _granulePosition += samplesPerPacket;

      final isLast = i == packets.length - 1;
      final headerType = isLast ? 0x04 : 0x00; // EOS flag on last page

      await _writePage(packets[i], headerType: headerType, granulePosition: _granulePosition);
    }

    LogService().log('OggOpusWriter: Wrote ${packets.length} packets, granule=$_granulePosition');
  }

  /// Close the file.
  Future<void> close() async {
    await _raf.close();
    LogService().log('OggOpusWriter: File closed');
  }

  /// Build the OpusHead identification header.
  /// See RFC 7845 Section 5.1
  Uint8List _buildOpusHead() {
    final buffer = BytesBuilder();

    // Magic signature "OpusHead"
    buffer.add([0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64]);

    // Version (1)
    buffer.addByte(1);

    // Channel count
    buffer.addByte(channels);

    // Pre-skip (little-endian 16-bit)
    buffer.addByte(preSkip & 0xFF);
    buffer.addByte((preSkip >> 8) & 0xFF);

    // Input sample rate (little-endian 32-bit)
    buffer.addByte(sampleRate & 0xFF);
    buffer.addByte((sampleRate >> 8) & 0xFF);
    buffer.addByte((sampleRate >> 16) & 0xFF);
    buffer.addByte((sampleRate >> 24) & 0xFF);

    // Output gain (0 = no gain)
    buffer.addByte(0);
    buffer.addByte(0);

    // Channel mapping family (0 = mono/stereo, no mapping table)
    buffer.addByte(0);

    return buffer.toBytes();
  }

  /// Build the OpusTags comment header.
  /// See RFC 7845 Section 5.2
  Uint8List _buildOpusTags() {
    final buffer = BytesBuilder();

    // Magic signature "OpusTags"
    buffer.add([0x4F, 0x70, 0x75, 0x73, 0x54, 0x61, 0x67, 0x73]);

    // Vendor string length (little-endian 32-bit)
    const vendor = 'geogram';
    buffer.addByte(vendor.length & 0xFF);
    buffer.addByte((vendor.length >> 8) & 0xFF);
    buffer.addByte((vendor.length >> 16) & 0xFF);
    buffer.addByte((vendor.length >> 24) & 0xFF);

    // Vendor string
    buffer.add(vendor.codeUnits);

    // User comment list length (0 comments)
    buffer.addByte(0);
    buffer.addByte(0);
    buffer.addByte(0);
    buffer.addByte(0);

    return buffer.toBytes();
  }

  /// Write an OGG page containing the given data.
  Future<void> _writePage(
    Uint8List data, {
    required int headerType,
    required int granulePosition,
  }) async {
    final page = BytesBuilder();

    // Capture pattern "OggS"
    page.add([0x4F, 0x67, 0x67, 0x53]);

    // Stream structure version (0)
    page.addByte(0);

    // Header type flag
    page.addByte(headerType);

    // Granule position (little-endian 64-bit)
    page.addByte(granulePosition & 0xFF);
    page.addByte((granulePosition >> 8) & 0xFF);
    page.addByte((granulePosition >> 16) & 0xFF);
    page.addByte((granulePosition >> 24) & 0xFF);
    page.addByte((granulePosition >> 32) & 0xFF);
    page.addByte((granulePosition >> 40) & 0xFF);
    page.addByte((granulePosition >> 48) & 0xFF);
    page.addByte((granulePosition >> 56) & 0xFF);

    // Bitstream serial number (little-endian 32-bit)
    page.addByte(_serialNumber & 0xFF);
    page.addByte((_serialNumber >> 8) & 0xFF);
    page.addByte((_serialNumber >> 16) & 0xFF);
    page.addByte((_serialNumber >> 24) & 0xFF);

    // Page sequence number (little-endian 32-bit)
    page.addByte(_pageSequence & 0xFF);
    page.addByte((_pageSequence >> 8) & 0xFF);
    page.addByte((_pageSequence >> 16) & 0xFF);
    page.addByte((_pageSequence >> 24) & 0xFF);
    _pageSequence++;

    // CRC checksum placeholder (will be filled in later)
    final crcOffset = page.length;
    page.addByte(0);
    page.addByte(0);
    page.addByte(0);
    page.addByte(0);

    // Segment table
    final segments = _buildSegmentTable(data.length);
    page.addByte(segments.length); // Number of segments
    page.add(segments);

    // Page data
    page.add(data);

    // Calculate CRC and update
    final pageBytes = page.toBytes();
    final crc = _calculateCrc32(pageBytes);
    pageBytes[crcOffset] = crc & 0xFF;
    pageBytes[crcOffset + 1] = (crc >> 8) & 0xFF;
    pageBytes[crcOffset + 2] = (crc >> 16) & 0xFF;
    pageBytes[crcOffset + 3] = (crc >> 24) & 0xFF;

    await _raf.writeFrom(pageBytes);
  }

  /// Build the segment table for a given data length.
  /// Each segment can be at most 255 bytes.
  List<int> _buildSegmentTable(int dataLength) {
    final segments = <int>[];
    var remaining = dataLength;

    while (remaining >= 255) {
      segments.add(255);
      remaining -= 255;
    }
    segments.add(remaining); // Final segment (or 0 if exact multiple of 255)

    return segments;
  }

  /// Calculate OGG CRC-32.
  /// Uses the polynomial 0x04C11DB7 with reflected input/output.
  int _calculateCrc32(Uint8List data) {
    // OGG uses a specific CRC-32 polynomial
    const polynomial = 0x04C11DB7;

    // Build lookup table on first use
    _crcTable ??= _buildCrcTable(polynomial);

    var crc = 0;
    for (final byte in data) {
      crc = ((crc << 8) ^ _crcTable![(crc >> 24) ^ byte]) & 0xFFFFFFFF;
    }
    return crc;
  }

  static List<int>? _crcTable;

  static List<int> _buildCrcTable(int polynomial) {
    final table = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      var r = i << 24;
      for (var j = 0; j < 8; j++) {
        if ((r & 0x80000000) != 0) {
          r = ((r << 1) ^ polynomial) & 0xFFFFFFFF;
        } else {
          r = (r << 1) & 0xFFFFFFFF;
        }
      }
      table[i] = r;
    }
    return table;
  }
}

/// Read PCM data from a WAV file.
/// Returns 16-bit signed PCM samples and sample rate.
class WavReader {
  /// Read a WAV file and return PCM samples.
  /// Returns (samples, sampleRate, channels).
  static Future<(Int16List, int, int)> read(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    final data = ByteData.sublistView(bytes);

    // Parse WAV header
    // Check RIFF header
    if (bytes[0] != 0x52 || bytes[1] != 0x49 || bytes[2] != 0x46 || bytes[3] != 0x46) {
      throw FormatException('Not a valid WAV file (missing RIFF header)');
    }

    // Check WAVE format
    if (bytes[8] != 0x57 || bytes[9] != 0x41 || bytes[10] != 0x56 || bytes[11] != 0x45) {
      throw FormatException('Not a valid WAV file (missing WAVE format)');
    }

    // Find fmt chunk
    var offset = 12;
    int? sampleRate;
    int? channels;
    int? bitsPerSample;

    while (offset < bytes.length - 8) {
      final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final chunkSize = data.getUint32(offset + 4, Endian.little);

      if (chunkId == 'fmt ') {
        // Audio format (1 = PCM)
        final audioFormat = data.getUint16(offset + 8, Endian.little);
        if (audioFormat != 1) {
          throw FormatException('Only PCM WAV files are supported');
        }

        channels = data.getUint16(offset + 10, Endian.little);
        sampleRate = data.getUint32(offset + 12, Endian.little);
        bitsPerSample = data.getUint16(offset + 22, Endian.little);

        if (bitsPerSample != 16) {
          throw FormatException('Only 16-bit WAV files are supported');
        }
      } else if (chunkId == 'data') {
        // Found data chunk
        final dataStart = offset + 8;
        final dataEnd = dataStart + chunkSize;

        if (sampleRate == null || channels == null) {
          throw FormatException('WAV file missing fmt chunk before data');
        }

        // Read 16-bit samples
        final numSamples = chunkSize ~/ 2;
        final samples = Int16List(numSamples);
        for (var i = 0; i < numSamples; i++) {
          samples[i] = data.getInt16(dataStart + i * 2, Endian.little);
        }

        LogService().log('WavReader: Read $numSamples samples, ${sampleRate}Hz, ${channels}ch');
        return (samples, sampleRate, channels);
      }

      offset += 8 + chunkSize;
      if (chunkSize % 2 != 0) offset++; // Padding byte
    }

    throw FormatException('WAV file missing data chunk');
  }
}

/// Read Opus packets from an OGG container file.
class OggOpusReader {
  /// Read an OGG Opus file and return Opus packets with sample rate and channels.
  /// Returns (packets, sampleRate, channels, preSkip).
  static Future<(List<Uint8List>, int, int, int)> read(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    final data = ByteData.sublistView(bytes);

    final packets = <Uint8List>[];
    var sampleRate = 48000;
    var channels = 1;
    var preSkip = 312;
    var offset = 0;
    var isFirstDataPacket = true;

    while (offset < bytes.length) {
      // Check for OggS magic
      if (offset + 27 > bytes.length) break;
      if (bytes[offset] != 0x4F ||
          bytes[offset + 1] != 0x67 ||
          bytes[offset + 2] != 0x67 ||
          bytes[offset + 3] != 0x53) {
        throw FormatException('Invalid OGG page at offset $offset');
      }

      // Parse page header
      // final version = bytes[offset + 4];
      // final headerType = bytes[offset + 5];
      // final granulePosition = data.getUint64(offset + 6, Endian.little);
      // final serialNumber = data.getUint32(offset + 14, Endian.little);
      // final pageSequence = data.getUint32(offset + 18, Endian.little);
      // final crc = data.getUint32(offset + 22, Endian.little);
      final numSegments = bytes[offset + 26];

      if (offset + 27 + numSegments > bytes.length) break;

      // Read segment table
      var pageDataSize = 0;
      for (var i = 0; i < numSegments; i++) {
        pageDataSize += bytes[offset + 27 + i];
      }

      final pageDataOffset = offset + 27 + numSegments;
      if (pageDataOffset + pageDataSize > bytes.length) break;

      // Extract page data (may contain one or more packets)
      final pageData = bytes.sublist(pageDataOffset, pageDataOffset + pageDataSize);

      // Parse packet(s) from page data
      var packetOffset = 0;
      var segmentIndex = 0;
      while (segmentIndex < numSegments) {
        // Collect segments until we find one < 255 (end of packet)
        var packetSize = 0;
        while (segmentIndex < numSegments) {
          final segSize = bytes[offset + 27 + segmentIndex];
          packetSize += segSize;
          segmentIndex++;
          if (segSize < 255) break; // End of packet
        }

        if (packetSize > 0 && packetOffset + packetSize <= pageData.length) {
          final packet = Uint8List.fromList(
              pageData.sublist(packetOffset, packetOffset + packetSize));

          // Check for OpusHead header
          if (packet.length >= 8 &&
              packet[0] == 0x4F &&
              packet[1] == 0x70 &&
              packet[2] == 0x75 &&
              packet[3] == 0x73 &&
              packet[4] == 0x48 &&
              packet[5] == 0x65 &&
              packet[6] == 0x61 &&
              packet[7] == 0x64) {
            // OpusHead packet
            if (packet.length >= 19) {
              channels = packet[9];
              preSkip = packet[10] | (packet[11] << 8);
              sampleRate = packet[12] |
                  (packet[13] << 8) |
                  (packet[14] << 16) |
                  (packet[15] << 24);
              LogService().log(
                  'OggOpusReader: OpusHead: ${sampleRate}Hz, ${channels}ch, preSkip=$preSkip');
            }
          } else if (packet.length >= 8 &&
              packet[0] == 0x4F &&
              packet[1] == 0x70 &&
              packet[2] == 0x75 &&
              packet[3] == 0x73 &&
              packet[4] == 0x54 &&
              packet[5] == 0x61 &&
              packet[6] == 0x67 &&
              packet[7] == 0x73) {
            // OpusTags packet - skip it
          } else {
            // Audio packet
            packets.add(packet);
            if (isFirstDataPacket) {
              LogService().log(
                  'OggOpusReader: First audio packet: ${packet.length} bytes');
              isFirstDataPacket = false;
            }
          }

          packetOffset += packetSize;
        }
      }

      offset = pageDataOffset + pageDataSize;
    }

    LogService().log(
        'OggOpusReader: Read ${packets.length} packets from $filePath');
    return (packets, sampleRate, channels, preSkip);
  }
}
