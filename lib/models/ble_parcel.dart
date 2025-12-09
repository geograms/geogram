/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:math';
import 'dart:typed_data';
import 'package:archive/archive.dart';

/// BLE Parcel Protocol Constants
class BLEParcelConstants {
  /// Maximum parcel size (proven stable for BLE transmission)
  static const int maxParcelSize = 280;

  /// Header parcel overhead: MSG_ID(2) + TOTAL(2) + CRC32(4) + FLAGS(1) = 9 bytes
  static const int headerOverhead = 9;

  /// Data parcel overhead: MSG_ID(2) + PARCEL_NUM(2) = 4 bytes
  static const int dataOverhead = 4;

  /// Max data in header parcel
  static const int headerDataCapacity = maxParcelSize - headerOverhead; // 271

  /// Max data in data parcel
  static const int dataParcelCapacity = maxParcelSize - dataOverhead; // 276

  /// Delay between parcels (ms)
  static const int interParcelDelayMs = 500;

  /// Delay between chunks within a parcel (ms)
  static const int intraChunkDelayMs = 30;

  /// Listen window every N parcels
  static const int parcelsBeforePause = 5;

  /// Listen window duration (ms)
  static const int listenWindowMs = 200;

  /// Receipt timeout (ms)
  static const int receiptTimeoutMs = 10000;

  /// Maximum retries for failed parcels
  static const int maxRetries = 3;

  /// Compression algorithm constants (stored in lower 4 bits of FLAGS)
  static const int compressionNone = 0x00;
  static const int compressionDeflate = 0x01;
  // Reserved: 0x02 = Zstandard, 0x03 = LZ4, etc.

  /// Minimum payload size to consider compression (bytes)
  static const int compressionThreshold = 300;
}

/// Compression utilities for BLE parcel protocol
class BLECompression {
  /// Compress data using the specified algorithm
  /// Returns compressed data, or original data if compression fails or isn't beneficial
  static Uint8List compress(Uint8List data, int algorithm) {
    if (algorithm == BLEParcelConstants.compressionNone) {
      return data;
    }

    if (algorithm == BLEParcelConstants.compressionDeflate) {
      try {
        final compressed = Uint8List.fromList(
          ZLibEncoder().encode(data),
        );
        // Only use compression if it actually reduces size
        if (compressed.length < data.length) {
          return compressed;
        }
      } catch (e) {
        // Compression failed, return original
      }
    }

    return data;
  }

  /// Decompress data using the specified algorithm
  /// Returns decompressed data, or throws if decompression fails
  static Uint8List decompress(Uint8List data, int algorithm) {
    if (algorithm == BLEParcelConstants.compressionNone) {
      return data;
    }

    if (algorithm == BLEParcelConstants.compressionDeflate) {
      return Uint8List.fromList(
        ZLibDecoder().decodeBytes(data),
      );
    }

    throw ArgumentError('Unsupported compression algorithm: $algorithm');
  }

  /// Check if data should be compressed
  /// Returns true if compression is beneficial
  static bool shouldCompress(Uint8List data) {
    // Don't compress small payloads
    if (data.length < BLEParcelConstants.compressionThreshold) {
      return false;
    }

    // Don't compress already-compressed data
    if (_looksLikeCompressedData(data)) {
      return false;
    }

    return true;
  }

  /// Heuristic to detect already-compressed data
  static bool _looksLikeCompressedData(Uint8List data) {
    if (data.length < 4) return false;

    // Check for common compressed file signatures
    // PNG
    if (data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) {
      return true;
    }
    // JPEG
    if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) {
      return true;
    }
    // GZIP
    if (data[0] == 0x1F && data[1] == 0x8B) {
      return true;
    }
    // ZLIB (deflate with zlib header)
    if ((data[0] == 0x78 && (data[1] == 0x01 || data[1] == 0x5E || data[1] == 0x9C || data[1] == 0xDA))) {
      return true;
    }
    // ZIP
    if (data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04) {
      return true;
    }

    return false;
  }
}

/// Generates a 2-letter message ID (A-Z)
String generateMessageId() {
  final random = Random();
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  return String.fromCharCodes([
    chars.codeUnitAt(random.nextInt(26)),
    chars.codeUnitAt(random.nextInt(26)),
  ]);
}

/// Calculate CRC32 checksum
/// Uses standard CRC-32 polynomial
int calculateCrc32(Uint8List data) {
  const polynomial = 0xEDB88320;
  int crc = 0xFFFFFFFF;

  for (final byte in data) {
    crc ^= byte;
    for (int i = 0; i < 8; i++) {
      if ((crc & 1) != 0) {
        crc = (crc >> 1) ^ polynomial;
      } else {
        crc >>= 1;
      }
    }
  }

  return crc ^ 0xFFFFFFFF;
}

/// Represents a BLE parcel (either header or data)
class BLEParcel {
  /// 2-letter message ID
  final String msgId;

  /// Parcel number (0 = header, 1+ = data parcels)
  final int parcelNum;

  /// Total number of parcels (only set in header, 0 otherwise)
  final int totalParcels;

  /// CRC32 checksum of complete message (only in header, 0 otherwise)
  final int checksum;

  /// FLAGS byte (only in header, 0 otherwise)
  /// Lower 4 bits: compression algorithm (0=none, 1=deflate)
  /// Upper 4 bits: reserved for future use
  final int flags;

  /// Payload data for this parcel
  final Uint8List data;

  /// True if this is the header parcel
  bool get isHeader => parcelNum == 0;

  /// Get compression algorithm from flags (lower 4 bits)
  int get compressionAlgorithm => flags & 0x0F;

  /// Check if payload is compressed
  bool get isCompressed => compressionAlgorithm != BLEParcelConstants.compressionNone;

  BLEParcel({
    required this.msgId,
    required this.parcelNum,
    this.totalParcels = 0,
    this.checksum = 0,
    this.flags = 0,
    required this.data,
  }) {
    if (msgId.length != 2) {
      throw ArgumentError('msgId must be exactly 2 characters');
    }
  }

  /// Create header parcel
  factory BLEParcel.header({
    required String msgId,
    required int totalParcels,
    required int checksum,
    int flags = 0,
    required Uint8List data,
  }) {
    if (data.length > BLEParcelConstants.headerDataCapacity) {
      throw ArgumentError(
        'Header data too large: ${data.length} > ${BLEParcelConstants.headerDataCapacity}',
      );
    }
    return BLEParcel(
      msgId: msgId,
      parcelNum: 0,
      totalParcels: totalParcels,
      checksum: checksum,
      flags: flags,
      data: data,
    );
  }

  /// Create data parcel
  factory BLEParcel.data({
    required String msgId,
    required int parcelNum,
    required Uint8List data,
  }) {
    if (parcelNum < 1) {
      throw ArgumentError('Data parcel number must be >= 1');
    }
    if (data.length > BLEParcelConstants.dataParcelCapacity) {
      throw ArgumentError(
        'Data parcel too large: ${data.length} > ${BLEParcelConstants.dataParcelCapacity}',
      );
    }
    return BLEParcel(
      msgId: msgId,
      parcelNum: parcelNum,
      data: data,
    );
  }

  /// Serialize parcel to bytes for transmission
  Uint8List toBytes() {
    final msgIdBytes = msgId.codeUnits;

    if (isHeader) {
      // Header format: [MSG_ID:2][TOTAL:2][CRC32:4][FLAGS:1][DATA:...]
      final buffer = ByteData(BLEParcelConstants.headerOverhead + data.length);
      buffer.setUint8(0, msgIdBytes[0]);
      buffer.setUint8(1, msgIdBytes[1]);
      buffer.setUint16(2, totalParcels, Endian.big);
      buffer.setUint32(4, checksum, Endian.big);
      buffer.setUint8(8, flags);

      final result = buffer.buffer.asUint8List();
      result.setRange(BLEParcelConstants.headerOverhead, result.length, data);
      return result;
    } else {
      // Data format: [MSG_ID:2][PARCEL_NUM:2][DATA:...]
      final buffer = ByteData(BLEParcelConstants.dataOverhead + data.length);
      buffer.setUint8(0, msgIdBytes[0]);
      buffer.setUint8(1, msgIdBytes[1]);
      buffer.setUint16(2, parcelNum, Endian.big);

      final result = buffer.buffer.asUint8List();
      result.setRange(BLEParcelConstants.dataOverhead, result.length, data);
      return result;
    }
  }

  /// Parse parcel from received bytes
  /// Returns null if parsing fails
  static BLEParcel? fromBytes(Uint8List bytes) {
    if (bytes.length < 4) return null;

    try {
      final msgId = String.fromCharCodes(bytes.sublist(0, 2));
      final byteData = ByteData.sublistView(bytes);

      // Check if this is a header parcel by examining if bytes 2-3 is 0 (parcel num)
      // Headers have totalParcels at bytes 2-3 which is > 0
      // Data parcels have parcelNum at bytes 2-3 which is > 0
      // We need another way to distinguish...

      // Actually, we need to know from context. For now, try header first.
      // If we have at least 9 bytes and the value at 2-3 makes sense as totalParcels
      // and value at 4-7 looks like a checksum, it's likely a header.

      // Better approach: parcelNum 0 is reserved for header
      // So if bytes[2-3] == 0, we know it's not valid as data parcel

      final value16 = byteData.getUint16(2, Endian.big);

      if (bytes.length >= BLEParcelConstants.headerOverhead) {
        // Could be header - check if we have enough data
        final potentialTotal = value16;
        final potentialChecksum = byteData.getUint32(4, Endian.big);
        final potentialFlags = byteData.getUint8(8);

        // Heuristic: if totalParcels > 0 and < 1000, likely header
        if (potentialTotal > 0 && potentialTotal < 1000) {
          // Treat as header
          return BLEParcel(
            msgId: msgId,
            parcelNum: 0,
            totalParcels: potentialTotal,
            checksum: potentialChecksum,
            flags: potentialFlags,
            data: Uint8List.fromList(
              bytes.sublist(BLEParcelConstants.headerOverhead),
            ),
          );
        }
      }

      // Treat as data parcel
      final parcelNum = value16;
      if (parcelNum == 0) {
        // parcelNum 0 is reserved for header but we didn't parse as header
        return null;
      }

      return BLEParcel(
        msgId: msgId,
        parcelNum: parcelNum,
        data: Uint8List.fromList(
          bytes.sublist(BLEParcelConstants.dataOverhead),
        ),
      );
    } catch (e) {
      return null;
    }
  }

  /// Parse as header parcel explicitly
  static BLEParcel? fromBytesAsHeader(Uint8List bytes) {
    if (bytes.length < BLEParcelConstants.headerOverhead) return null;

    try {
      final msgId = String.fromCharCodes(bytes.sublist(0, 2));
      final byteData = ByteData.sublistView(bytes);

      return BLEParcel(
        msgId: msgId,
        parcelNum: 0,
        totalParcels: byteData.getUint16(2, Endian.big),
        checksum: byteData.getUint32(4, Endian.big),
        flags: byteData.getUint8(8),
        data: Uint8List.fromList(
          bytes.sublist(BLEParcelConstants.headerOverhead),
        ),
      );
    } catch (e) {
      return null;
    }
  }

  /// Parse as data parcel explicitly
  static BLEParcel? fromBytesAsData(Uint8List bytes) {
    if (bytes.length < BLEParcelConstants.dataOverhead) return null;

    try {
      final msgId = String.fromCharCodes(bytes.sublist(0, 2));
      final byteData = ByteData.sublistView(bytes);

      return BLEParcel(
        msgId: msgId,
        parcelNum: byteData.getUint16(2, Endian.big),
        data: Uint8List.fromList(
          bytes.sublist(BLEParcelConstants.dataOverhead),
        ),
      );
    } catch (e) {
      return null;
    }
  }

  @override
  String toString() {
    if (isHeader) {
      return 'BLEParcel.header(msgId=$msgId, total=$totalParcels, '
          'crc=${checksum.toRadixString(16)}, dataLen=${data.length})';
    }
    return 'BLEParcel.data(msgId=$msgId, num=$parcelNum, dataLen=${data.length})';
  }
}

/// Represents an outgoing message to be split into parcels
class BLEOutgoingMessage {
  /// Unique message ID
  final String msgId;

  /// Complete payload data
  final Uint8List payload;

  /// Target device ID
  final String targetDeviceId;

  /// Timestamp when message was enqueued
  final DateTime enqueuedAt;

  /// Number of retry attempts
  int retryCount = 0;

  /// Whether peer supports compression (set by caller based on capability negotiation)
  final bool peerSupportsCompression;

  BLEOutgoingMessage({
    String? msgId,
    required this.payload,
    required this.targetDeviceId,
    this.peerSupportsCompression = false,
  })  : msgId = msgId ?? generateMessageId(),
        enqueuedAt = DateTime.now();

  /// Split payload into parcels, optionally compressing if beneficial
  List<BLEParcel> toParcels() {
    // Decide whether to compress
    Uint8List dataToSend = payload;
    int flags = BLEParcelConstants.compressionNone;

    if (peerSupportsCompression && BLECompression.shouldCompress(payload)) {
      final compressed = BLECompression.compress(
        payload,
        BLEParcelConstants.compressionDeflate,
      );
      // Only use compression if it actually reduced the size
      if (compressed.length < payload.length) {
        dataToSend = compressed;
        flags = BLEParcelConstants.compressionDeflate;
      }
    }

    // CRC32 is calculated on the data being transmitted (compressed or not)
    final checksum = calculateCrc32(dataToSend);
    final parcels = <BLEParcel>[];

    // Calculate how many parcels we need
    int remaining = dataToSend.length;
    int offset = 0;

    // First parcel (header)
    final headerDataSize = min(remaining, BLEParcelConstants.headerDataCapacity);
    final headerData = Uint8List.fromList(
      dataToSend.sublist(offset, offset + headerDataSize),
    );
    offset += headerDataSize;
    remaining -= headerDataSize;

    // Calculate total parcels needed
    int totalParcels = 1; // header
    if (remaining > 0) {
      totalParcels += (remaining / BLEParcelConstants.dataParcelCapacity).ceil();
    }

    parcels.add(BLEParcel.header(
      msgId: msgId,
      totalParcels: totalParcels,
      checksum: checksum,
      flags: flags,
      data: headerData,
    ));

    // Data parcels
    int parcelNum = 1;
    while (remaining > 0) {
      final dataSize = min(remaining, BLEParcelConstants.dataParcelCapacity);
      final parcelData = Uint8List.fromList(
        dataToSend.sublist(offset, offset + dataSize),
      );
      offset += dataSize;
      remaining -= dataSize;

      parcels.add(BLEParcel.data(
        msgId: msgId,
        parcelNum: parcelNum,
        data: parcelData,
      ));
      parcelNum++;
    }

    return parcels;
  }

  @override
  String toString() {
    return 'BLEOutgoingMessage(msgId=$msgId, size=${payload.length}, '
        'target=$targetDeviceId, retries=$retryCount)';
  }
}

/// Represents an incoming message being assembled from parcels
class BLEIncomingMessage {
  /// Message ID
  final String msgId;

  /// Expected total parcels
  final int totalParcels;

  /// Expected checksum
  final int expectedChecksum;

  /// Compression flags from header (lower 4 bits = algorithm)
  final int flags;

  /// Received parcels by number (0 = header)
  final Map<int, Uint8List> _parcels = {};

  /// When first parcel was received
  final DateTime startedAt;

  /// When last parcel was received (for timeout detection)
  DateTime _lastParcelReceivedAt;

  /// When last missing parcel request was sent (to avoid spamming)
  DateTime? _lastMissingRequestAt;

  /// Source device ID
  final String sourceDeviceId;

  BLEIncomingMessage({
    required this.msgId,
    required this.totalParcels,
    required this.expectedChecksum,
    this.flags = 0,
    required this.sourceDeviceId,
  }) : startedAt = DateTime.now(),
       _lastParcelReceivedAt = DateTime.now();

  /// Get compression algorithm from flags
  int get compressionAlgorithm => flags & 0x0F;

  /// Check if payload is compressed
  bool get isCompressed => compressionAlgorithm != BLEParcelConstants.compressionNone;

  /// Get last parcel received timestamp
  DateTime get lastParcelReceivedAt => _lastMissingRequestAt ?? _lastParcelReceivedAt;

  /// Mark that a missing parcel request was sent
  void markParcelRequestSent() {
    _lastMissingRequestAt = DateTime.now();
  }

  /// Add a parcel to this message
  void addParcel(BLEParcel parcel) {
    if (parcel.msgId != msgId) {
      throw ArgumentError('Parcel msgId mismatch');
    }
    _parcels[parcel.parcelNum] = parcel.data;
    _lastParcelReceivedAt = DateTime.now();
    // Reset missing request timer when we receive a parcel
    _lastMissingRequestAt = null;
  }

  /// Check if all parcels received
  bool get isComplete => _parcels.length == totalParcels;

  /// Get list of missing parcel numbers
  List<int> get missingParcels {
    final missing = <int>[];
    for (int i = 0; i < totalParcels; i++) {
      if (!_parcels.containsKey(i)) {
        missing.add(i);
      }
    }
    return missing;
  }

  /// Get number of received parcels
  int get receivedCount => _parcels.length;

  /// Assemble complete payload from parcels
  /// Returns null if not complete or checksum fails
  /// Automatically decompresses if payload was compressed
  Uint8List? assemble() {
    if (!isComplete) return null;

    // Calculate total size
    int totalSize = 0;
    for (int i = 0; i < totalParcels; i++) {
      totalSize += _parcels[i]!.length;
    }

    // Assemble received data
    final receivedData = Uint8List(totalSize);
    int offset = 0;
    for (int i = 0; i < totalParcels; i++) {
      final parcelData = _parcels[i]!;
      receivedData.setRange(offset, offset + parcelData.length, parcelData);
      offset += parcelData.length;
    }

    // Verify checksum on received (potentially compressed) data
    final actualChecksum = calculateCrc32(receivedData);
    if (actualChecksum != expectedChecksum) {
      return null;
    }

    // Decompress if necessary
    if (isCompressed) {
      try {
        return BLECompression.decompress(receivedData, compressionAlgorithm);
      } catch (e) {
        // Decompression failed
        return null;
      }
    }

    return receivedData;
  }

  /// Check if message has timed out (stale)
  bool isStale({Duration timeout = const Duration(seconds: 60)}) {
    return DateTime.now().difference(startedAt) > timeout;
  }

  @override
  String toString() {
    return 'BLEIncomingMessage(msgId=$msgId, received=${_parcels.length}/$totalParcels, '
        'from=$sourceDeviceId)';
  }
}

/// Receipt message types
enum BLEReceiptStatus {
  complete,
  missing,
  checksumFailed,
}

/// Receipt message for acknowledging message transmission
class BLEReceipt {
  final String msgId;
  final BLEReceiptStatus status;
  final List<int>? missingParcels;

  BLEReceipt({
    required this.msgId,
    required this.status,
    this.missingParcels,
  });

  /// Create complete receipt
  factory BLEReceipt.complete(String msgId) {
    return BLEReceipt(msgId: msgId, status: BLEReceiptStatus.complete);
  }

  /// Create missing parcels receipt
  factory BLEReceipt.missing(String msgId, List<int> parcels) {
    return BLEReceipt(
      msgId: msgId,
      status: BLEReceiptStatus.missing,
      missingParcels: parcels,
    );
  }

  /// Create checksum failed receipt
  factory BLEReceipt.checksumFailed(String msgId) {
    return BLEReceipt(msgId: msgId, status: BLEReceiptStatus.checksumFailed);
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'msg_id': msgId,
      'status': status.name,
    };
    if (missingParcels != null) {
      json['parcels'] = missingParcels;
    }
    return json;
  }

  /// Parse from JSON
  factory BLEReceipt.fromJson(Map<String, dynamic> json) {
    final statusStr = json['status'] as String;
    final status = BLEReceiptStatus.values.firstWhere(
      (s) => s.name == statusStr,
      orElse: () => throw ArgumentError('Unknown status: $statusStr'),
    );

    return BLEReceipt(
      msgId: json['msg_id'] as String,
      status: status,
      missingParcels: (json['parcels'] as List?)?.cast<int>(),
    );
  }

  @override
  String toString() {
    if (status == BLEReceiptStatus.missing) {
      return 'BLEReceipt(msgId=$msgId, missing=$missingParcels)';
    }
    return 'BLEReceipt(msgId=$msgId, status=${status.name})';
  }
}
