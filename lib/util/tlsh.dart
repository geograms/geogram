import 'dart:typed_data';

/// Pure Dart implementation of TLSH (Trend Micro Locality Sensitive Hash)
/// Based on the original C++ implementation
class TLSH {
  static const int _buckets = 256;
  static const int _effectiveBuckets = 128;
  static const int _codeSize = 32;
  static const int _windowLength = 5;
  static const int _checksumLength = 1;

  // Pearson hash table for quartile calculation
  static const List<int> _pearsonTable = [
    1, 87, 49, 12, 176, 178, 102, 166, 121, 193, 6, 84, 249, 230, 44, 163,
    14, 197, 213, 181, 161, 85, 218, 80, 64, 239, 24, 226, 236, 142, 38, 200,
    110, 177, 104, 103, 141, 253, 255, 50, 77, 101, 81, 18, 45, 96, 31, 222,
    25, 107, 190, 70, 86, 237, 240, 34, 72, 242, 20, 214, 244, 227, 149, 235,
    97, 234, 57, 22, 60, 250, 82, 175, 208, 5, 127, 199, 111, 62, 135, 248,
    174, 169, 211, 58, 66, 154, 106, 195, 245, 171, 17, 187, 182, 179, 0, 243,
    132, 56, 148, 75, 128, 133, 158, 100, 130, 126, 91, 13, 153, 246, 216, 219,
    119, 68, 223, 78, 83, 88, 201, 99, 122, 11, 92, 32, 136, 114, 52, 10,
    138, 30, 48, 183, 156, 35, 61, 26, 143, 74, 251, 94, 129, 162, 63, 152,
    170, 7, 115, 167, 241, 206, 3, 150, 55, 59, 151, 220, 90, 53, 23, 131,
    125, 173, 15, 238, 79, 95, 89, 16, 105, 137, 225, 224, 217, 160, 37, 123,
    118, 73, 2, 157, 46, 116, 9, 145, 134, 228, 207, 212, 202, 215, 69, 229,
    27, 188, 67, 124, 168, 252, 42, 4, 29, 108, 21, 247, 19, 205, 39, 203,
    233, 40, 186, 147, 198, 192, 155, 33, 164, 191, 98, 204, 165, 180, 117, 76,
    140, 36, 210, 172, 41, 54, 159, 8, 185, 232, 113, 196, 231, 47, 146, 120,
    51, 65, 28, 144, 254, 221, 93, 189, 194, 139, 112, 43, 71, 109, 184, 209,
  ];

  /// Calculate TLSH hash from bytes
  static String? hash(Uint8List data) {
    if (data.length < 50) {
      return null; // TLSH requires minimum 50 bytes
    }

    // Initialize buckets
    final buckets = List<int>.filled(_buckets, 0);

    // Sliding window processing
    int aFull = 0;
    int bFull = 0;
    int checksum = 0;

    for (int i = 0; i < data.length - _windowLength + 1; i++) {
      // Calculate triplets for 5-byte window
      int r1 = data[i];
      int r2 = data[i + 1];
      int r3 = data[i + 2];
      int r4 = data[i + 3];
      int r5 = data[i + 4];

      // Pearson hashing
      int salt = 0;
      checksum = _pearsonHash(salt, checksum, r1);
      salt++;
      checksum = _pearsonHash(salt, checksum, r2);
      salt++;
      checksum = _pearsonHash(salt, checksum, r3);
      salt++;

      // Generate bucket indices using triplet combinations
      int h1 = _b_mapping(0, r1, r2, r3);
      int h2 = _b_mapping(1, r1, r2, r3);
      int h3 = _b_mapping(0, r2, r3, r4);
      int h4 = _b_mapping(1, r2, r3, r4);
      int h5 = _b_mapping(0, r3, r4, r5);
      int h6 = _b_mapping(1, r3, r4, r5);

      buckets[h1]++;
      buckets[h2]++;
      buckets[h3]++;
      buckets[h4]++;
      buckets[h5]++;
      buckets[h6]++;

      aFull++;
      if (i >= 1) bFull++;
    }

    // Calculate quartiles
    final q = _calculateQuartiles(buckets, aFull * 6);

    // Encode hash
    return _encodeHash(data.length, checksum, buckets, q);
  }

  /// Pearson hash function
  static int _pearsonHash(int salt, int checksum, int byte) {
    int h = _pearsonTable[salt];
    h = _pearsonTable[h ^ byte];
    return h ^ checksum;
  }

  /// Bucket mapping function
  static int _b_mapping(int salt, int i, int j, int k) {
    int h = 0;
    h = _pearsonTable[h ^ i];
    h = _pearsonTable[h ^ j];
    h = _pearsonTable[h ^ k];
    return salt == 0 ? h : (_pearsonTable[(h + salt) & 0xFF]);
  }

  /// Calculate quartile values
  static List<int> _calculateQuartiles(List<int> buckets, int nonzero) {
    final spl = List<int>.filled(256, 0);

    // Count bucket frequencies
    for (int i = 0; i < _effectiveBuckets; i++) {
      int val = buckets[i];
      if (val > 255) val = 255;
      spl[val]++;
    }

    // Calculate cumulative distribution
    int total = 0;
    for (int i = 0; i < 256; i++) {
      total += spl[i];
      spl[i] = total;
    }

    // Find quartile thresholds
    int q1 = (nonzero / 4).floor();
    int q2 = (nonzero / 2).floor();
    int q3 = (nonzero * 3 / 4).floor();

    int q1Pos = 0, q2Pos = 0, q3Pos = 0;
    for (int i = 0; i < 256; i++) {
      if (spl[i] <= q1) q1Pos = i;
      if (spl[i] <= q2) q2Pos = i;
      if (spl[i] <= q3) q3Pos = i;
    }

    return [q1Pos, q2Pos, q3Pos];
  }

  /// Encode final hash string
  static String _encodeHash(int length, int checksum, List<int> buckets, List<int> q) {
    final result = StringBuffer();

    // Length encoding (log scale)
    int lValue = 0;
    if (length >= 50) {
      int l = (length / 256).floor();
      if (l <= 1) {
        lValue = length & 0xFF;
      } else if (l <= 3) {
        lValue = l + 255;
      } else {
        lValue = 258;
      }
    }

    // Checksum
    result.write(_toHex(checksum, 2));

    // Length
    result.write(_toHex(lValue, 2));

    // Q1, Q2, Q3 ratios
    int q1Ratio = ((q[0] * 16 / (q[2] + 1)).floor() & 0x0F);
    int q2Ratio = ((q[1] * 16 / (q[2] + 1)).floor() & 0x0F);
    result.write(_toHex((q1Ratio << 4) | q2Ratio, 2));

    // Encode buckets (quantized to 2 bits per bucket)
    for (int i = 0; i < _effectiveBuckets / 4; i++) {
      int val = 0;
      for (int j = 0; j < 4; j++) {
        int idx = i * 4 + j;
        int b = buckets[idx];

        // Quantize to 2 bits based on quartiles
        int code = 0;
        if (b > q[2]) {
          code = 3;
        } else if (b > q[1]) {
          code = 2;
        } else if (b > q[0]) {
          code = 1;
        }

        val = (val << 2) | code;
      }
      result.write(_toHex(val, 2));
    }

    return result.toString().toUpperCase();
  }

  /// Convert integer to hex string
  static String _toHex(int value, int length) {
    return value.toRadixString(16).padLeft(length, '0');
  }
}
