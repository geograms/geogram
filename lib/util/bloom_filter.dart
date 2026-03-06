/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Bloom filter for probabilistic set membership — pure Dart, no deps.
 * Used for message UUID deduplication in mesh/relay protocols.
 */

import 'dart:typed_data';

class BloomFilter {
  final Uint8List _bits;
  final int _bitCount;
  final int _hashCount;
  int _itemCount = 0;

  /// Create a bloom filter with the given expected [capacity] and
  /// false-positive [errorRate] (default 1%).
  factory BloomFilter({int capacity = 10000, double errorRate = 0.01}) {
    // Optimal bit count: m = -n*ln(p) / (ln2)^2
    final m = (-(capacity * _ln(errorRate)) / (_ln2 * _ln2)).ceil();
    // Optimal hash count: k = (m/n) * ln2
    final k = ((m / capacity) * _ln2).ceil().clamp(1, 20);
    return BloomFilter._(Uint8List((m + 7) >> 3), m, k);
  }

  /// Create a bloom filter with explicit bit count and hash count.
  BloomFilter._(this._bits, this._bitCount, this._hashCount);

  /// Number of items added.
  int get itemCount => _itemCount;

  /// Add an item (as bytes) to the filter.
  void add(List<int> data) {
    final hashes = _hashes(data);
    for (final h in hashes) {
      final pos = h % _bitCount;
      _bits[pos >> 3] |= 1 << (pos & 7);
    }
    _itemCount++;
  }

  /// Add a string item to the filter.
  void addString(String s) {
    add(s.codeUnits);
  }

  /// Test if an item might be in the filter.
  /// Returns false if definitely not present, true if possibly present.
  bool mightContain(List<int> data) {
    final hashes = _hashes(data);
    for (final h in hashes) {
      final pos = h % _bitCount;
      if ((_bits[pos >> 3] & (1 << (pos & 7))) == 0) return false;
    }
    return true;
  }

  /// Test if a string might be in the filter.
  bool mightContainString(String s) {
    return mightContain(s.codeUnits);
  }

  /// Reset the filter.
  void clear() {
    _bits.fillRange(0, _bits.length, 0);
    _itemCount = 0;
  }

  /// Generate [_hashCount] hash values using double-hashing (Kirsch-Mitzenmacker).
  List<int> _hashes(List<int> data) {
    final h1 = _fnv1a(data);
    final h2 = _murmur(data);
    return List.generate(
      _hashCount,
      (i) => ((h1 + i * h2) & 0x7FFFFFFF),
    );
  }

  /// FNV-1a hash (32-bit).
  static int _fnv1a(List<int> data) {
    int hash = 0x811c9dc5;
    for (final b in data) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  /// Simple Murmur-inspired hash for the second hash function.
  static int _murmur(List<int> data) {
    int hash = 0;
    for (final b in data) {
      hash = ((hash + b) * 0x5bd1e995) & 0xFFFFFFFF;
      hash ^= hash >> 15;
    }
    return hash;
  }

  static double _ln(double x) {
    // Natural log approximation using dart:core
    return x > 0 ? _log(x) : double.negativeInfinity;
  }

  static const double _ln2 = 0.6931471805599453;

  static double _log(double x) {
    // Use the identity: ln(x) = log2(x) * ln(2)
    // dart doesn't have log() in core, so use a series or import
    // Actually, dart:math has log() but we avoid importing it to keep pure
    // Let's use the Taylor series around 1: ln(x) = sum((-1)^(n+1) * (x-1)^n / n)
    // But that only converges for 0 < x <= 2. Use range reduction.
    if (x <= 0) return double.negativeInfinity;
    if (x == 1) return 0;

    // Range reduction: x = m * 2^e where 0.5 <= m < 1
    int e = 0;
    double m = x;
    while (m >= 2) {
      m /= 2;
      e++;
    }
    while (m < 0.5) {
      m *= 2;
      e--;
    }

    // ln(x) = ln(m) + e * ln(2)
    // ln(m) via series: m is in [0.5, 2)
    final t = (m - 1) / (m + 1);
    final t2 = t * t;
    double sum = t;
    double term = t;
    for (int n = 3; n <= 21; n += 2) {
      term *= t2;
      sum += term / n;
    }
    return 2 * sum + e * _ln2;
  }
}
