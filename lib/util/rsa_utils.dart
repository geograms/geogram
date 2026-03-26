/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared RSA / ASN.1-DER / PEM utilities.
 *
 * Used by SslCertificateManager (Let's Encrypt ACME on Android),
 * DkimKeyGenerator (email signing), and DkimSigner.
 *
 * All operations are pure Dart (pointycastle) — no openssl CLI dependency.
 */

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

// Re-export key types so consumers don't need pointycastle directly
export 'package:pointycastle/export.dart' show RSAPublicKey, RSAPrivateKey;

// ---------------------------------------------------------------------------
// Secure random — shared singleton
// ---------------------------------------------------------------------------

final _secureRandom = SecureRandom('Fortuna')
  ..seed(KeyParameter(
    Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(256))),
  ));

// ---------------------------------------------------------------------------
// RSA key generation
// ---------------------------------------------------------------------------

/// Generate an RSA key pair of the given [bitLength] (e.g. 2048, 4096).
AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> generateRsaKeyPair(
    int bitLength) {
  final keyParams =
      RSAKeyGeneratorParameters(BigInt.from(65537), bitLength, 64);
  final params = ParametersWithRandom(keyParams, _secureRandom);
  final keyGenerator = RSAKeyGenerator()..init(params);
  final pair = keyGenerator.generateKeyPair();
  return AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey>(
    pair.publicKey as RSAPublicKey,
    pair.privateKey as RSAPrivateKey,
  );
}

// ---------------------------------------------------------------------------
// PEM encode / decode
// ---------------------------------------------------------------------------

/// Encode an RSA private key to PEM (PKCS#1) format.
String encodePrivateKeyPem(RSAPrivateKey key) {
  final bytes = _encodePrivateKeyDer(key);
  final b64 = base64.encode(bytes);
  final lines = <String>[];
  for (var i = 0; i < b64.length; i += 64) {
    lines.add(b64.substring(i, (i + 64).clamp(0, b64.length)));
  }
  return '-----BEGIN RSA PRIVATE KEY-----\n${lines.join('\n')}\n-----END RSA PRIVATE KEY-----';
}

/// Decode a PEM-encoded RSA private key (PKCS#1 or PKCS#8).
/// Returns null on failure.
RSAPrivateKey? decodePrivateKeyPem(String pem) {
  try {
    final stripped = pem
        .replaceAll('-----BEGIN RSA PRIVATE KEY-----', '')
        .replaceAll('-----END RSA PRIVATE KEY-----', '')
        .replaceAll('-----BEGIN PRIVATE KEY-----', '')
        .replaceAll('-----END PRIVATE KEY-----', '')
        .replaceAll(RegExp(r'\s'), '');
    final bytes = base64Decode(stripped);
    return _parseRsaPrivateKeyDer(bytes);
  } catch (_) {
    return null;
  }
}

/// Derive the public key from a private key.
RSAPublicKey publicKeyFromPrivate(RSAPrivateKey key) {
  return RSAPublicKey(key.modulus!, key.publicExponent!);
}

// ---------------------------------------------------------------------------
// DER encoding — public key
// ---------------------------------------------------------------------------

/// Encode RSA public key to DER (SubjectPublicKeyInfo).
Uint8List encodePublicKeyDer(RSAPublicKey key) {
  // PKCS#1 RSAPublicKey inner sequence
  final inner = DerSequence()
    ..addInteger(key.modulus!)
    ..addInteger(key.exponent!);
  final innerBytes = inner.encode();

  // AlgorithmIdentifier: rsaEncryption OID + NULL
  final algId = DerSequence()
    ..addOid([1, 2, 840, 113549, 1, 1, 1])
    ..addNull();

  // SubjectPublicKeyInfo wrapper
  final spki = DerSequence()
    ..addRaw(algId.encode())
    ..addBitString(innerBytes);

  return spki.encode();
}

// ---------------------------------------------------------------------------
// RSA-SHA256 signing
// ---------------------------------------------------------------------------

/// Sign [data] with RSA-SHA256 using the given [privateKey].
Uint8List rsaSign(List<int> data, RSAPrivateKey privateKey) {
  // DigestInfo OID prefix for SHA-256: 0609608648016503040201
  final signer = RSASigner(SHA256Digest(), '0609608648016503040201');
  signer.init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
  return signer.generateSignature(Uint8List.fromList(data)).bytes;
}

// ---------------------------------------------------------------------------
// CSR generation (PKCS#10)
// ---------------------------------------------------------------------------

/// Generate a PKCS#10 Certificate Signing Request in DER format.
Uint8List generateCsrDer(
    RSAPrivateKey privateKey, RSAPublicKey publicKey, String commonName) {
  // CertificationRequestInfo
  final certReqInfo = DerSequence();

  // version 0
  certReqInfo.addInteger(BigInt.zero);

  // subject: SEQUENCE { SET { SEQUENCE { OID, UTF8String } } }
  final atv = DerSequence()
    ..addOid([2, 5, 4, 3]) // id-at-commonName
    ..addUtf8String(commonName);
  final rdnSet = _wrapWithTag(0x31, atv.encode()); // SET wrapper
  final subject = DerSequence()..addRaw(rdnSet);
  certReqInfo.addRaw(subject.encode());

  // subjectPKInfo
  final algId = DerSequence()
    ..addOid([1, 2, 840, 113549, 1, 1, 1])
    ..addNull();
  final pkInner = DerSequence()
    ..addInteger(publicKey.modulus!)
    ..addInteger(publicKey.exponent!);
  final spki = DerSequence()
    ..addRaw(algId.encode())
    ..addBitString(pkInner.encode());
  certReqInfo.addRaw(spki.encode());

  // attributes [0] IMPLICIT (empty)
  certReqInfo.addRaw(Uint8List.fromList([0xa0, 0x00]));

  final certReqInfoBytes = certReqInfo.encode();

  // Sign certificationRequestInfo
  final signature = rsaSign(certReqInfoBytes, privateKey);

  // signatureAlgorithm: sha256WithRSAEncryption
  final sigAlg = DerSequence()
    ..addOid([1, 2, 840, 113549, 1, 1, 11])
    ..addNull();

  // CertificationRequest
  final csr = DerSequence()
    ..addRaw(certReqInfoBytes)
    ..addRaw(sigAlg.encode())
    ..addBitString(signature);

  return csr.encode();
}

// ---------------------------------------------------------------------------
// Self-signed X.509 certificate generation
// ---------------------------------------------------------------------------

/// Generate a self-signed X.509 certificate (DER).
/// Validity: [validDays] from now.
Uint8List generateSelfSignedCertDer(
    RSAPrivateKey privateKey, RSAPublicKey publicKey, String commonName,
    {int validDays = 365}) {
  final now = DateTime.now().toUtc();
  final notAfter = now.add(Duration(days: validDays));

  // TBSCertificate
  final tbs = DerSequence();

  // version [0] EXPLICIT v3
  tbs.addRaw(
      _wrapWithTag(0xa0, DerSequence.wrapTagAndLength(0x02, Uint8List.fromList([0x02]))));

  // serialNumber
  tbs.addInteger(BigInt.from(Random.secure().nextInt(0x7fffffff)));

  // signature algorithm: sha256WithRSAEncryption
  final sigAlg = DerSequence()
    ..addOid([1, 2, 840, 113549, 1, 1, 11])
    ..addNull();
  tbs.addRaw(sigAlg.encode());

  // issuer = subject (self-signed)
  // X.509 Name: SEQUENCE { SET { SEQUENCE { OID, UTF8String } } }
  final atv = DerSequence()
    ..addOid([2, 5, 4, 3])
    ..addUtf8String(commonName);
  final rdnSet = _wrapWithTag(0x31, atv.encode()); // SET wrapper
  final nameSeq = DerSequence()..addRaw(rdnSet);
  final nameBytes = nameSeq.encode();
  tbs.addRaw(nameBytes); // issuer

  // validity
  final validity = DerSequence()
    ..addUtcTime(now)
    ..addUtcTime(notAfter);
  tbs.addRaw(validity.encode());

  tbs.addRaw(nameBytes); // subject = issuer

  // subjectPublicKeyInfo
  final pkAlg = DerSequence()
    ..addOid([1, 2, 840, 113549, 1, 1, 1])
    ..addNull();
  final pkInner = DerSequence()
    ..addInteger(publicKey.modulus!)
    ..addInteger(publicKey.exponent!);
  final spki = DerSequence()
    ..addRaw(pkAlg.encode())
    ..addBitString(pkInner.encode());
  tbs.addRaw(spki.encode());

  final tbsBytes = tbs.encode();

  // Sign
  final signature = rsaSign(tbsBytes, privateKey);

  // Certificate
  final cert = DerSequence()
    ..addRaw(tbsBytes)
    ..addRaw(sigAlg.encode())
    ..addBitString(signature);

  return cert.encode();
}

/// Encode DER certificate bytes to PEM.
String encodeCertPem(Uint8List der) {
  final b64 = base64.encode(der);
  final lines = <String>[];
  for (var i = 0; i < b64.length; i += 64) {
    lines.add(b64.substring(i, (i + 64).clamp(0, b64.length)));
  }
  return '-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n-----END CERTIFICATE-----';
}

// ---------------------------------------------------------------------------
// X.509 certificate parsing (expiry extraction)
// ---------------------------------------------------------------------------

/// Parse a PEM certificate and return the notAfter date, or null on failure.
DateTime? parseCertificateExpiry(String pem) {
  try {
    final stripped = pem
        .replaceAll('-----BEGIN CERTIFICATE-----', '')
        .replaceAll('-----END CERTIFICATE-----', '')
        .replaceAll(RegExp(r'\s'), '');
    final bytes = base64Decode(stripped);
    return _extractNotAfter(Uint8List.fromList(bytes));
  } catch (_) {
    return null;
  }
}

/// Walk the ASN.1 DER structure to find the validity → notAfter field.
DateTime? _extractNotAfter(Uint8List certDer) {
  // Certificate → SEQUENCE → TBSCertificate → SEQUENCE
  // Inside TBS: version, serial, sigAlg, issuer, validity, subject, spki
  // validity is a SEQUENCE of two time values; notAfter is the second.
  int pos = 0;

  int readTag() => certDer[pos++];
  int readLength() {
    int b = certDer[pos++];
    if (b < 0x80) return b;
    int n = b & 0x7f;
    int len = 0;
    for (int i = 0; i < n; i++) {
      len = (len << 8) | certDer[pos++];
    }
    return len;
  }

  void skipElement() {
    pos++; // tag
    final len = readLength();
    pos += len;
  }

  // Outer SEQUENCE
  readTag();
  readLength();

  // TBSCertificate SEQUENCE
  readTag();
  readLength();

  // version [0] EXPLICIT — optional, check tag
  if (certDer[pos] == 0xa0) {
    skipElement();
  }

  // serialNumber
  skipElement();
  // signature algorithm
  skipElement();
  // issuer
  skipElement();

  // validity SEQUENCE
  readTag(); // 0x30
  readLength();

  // notBefore — skip
  readTag();
  final nbLen = readLength();
  pos += nbLen;

  // notAfter
  final naTag = readTag();
  final naLen = readLength();
  final naBytes = certDer.sublist(pos, pos + naLen);
  final timeStr = String.fromCharCodes(naBytes);

  // UTCTime (0x17): YYMMDDHHmmSSZ
  // GeneralizedTime (0x18): YYYYMMDDHHmmSSZ
  if (naTag == 0x17) {
    // UTCTime
    int yy = int.parse(timeStr.substring(0, 2));
    int year = yy >= 50 ? 1900 + yy : 2000 + yy;
    return DateTime.utc(
      year,
      int.parse(timeStr.substring(2, 4)),
      int.parse(timeStr.substring(4, 6)),
      int.parse(timeStr.substring(6, 8)),
      int.parse(timeStr.substring(8, 10)),
      int.parse(timeStr.substring(10, 12)),
    );
  } else if (naTag == 0x18) {
    // GeneralizedTime
    return DateTime.utc(
      int.parse(timeStr.substring(0, 4)),
      int.parse(timeStr.substring(4, 6)),
      int.parse(timeStr.substring(6, 8)),
      int.parse(timeStr.substring(8, 10)),
      int.parse(timeStr.substring(10, 12)),
      int.parse(timeStr.substring(12, 14)),
    );
  }
  return null;
}

// ---------------------------------------------------------------------------
// JWK helpers (for ACME)
// ---------------------------------------------------------------------------

/// Build a JWK Map from an RSA public key.
Map<String, dynamic> rsaPublicKeyToJwk(RSAPublicKey key) {
  final nBytes = _bigIntToUnsignedBytes(key.modulus!);
  final eBytes = _bigIntToUnsignedBytes(key.exponent!);
  return {
    'kty': 'RSA',
    'n': base64Url.encode(nBytes).replaceAll('=', ''),
    'e': base64Url.encode(eBytes).replaceAll('=', ''),
  };
}

/// Compute the JWK thumbprint (SHA-256) per RFC 7638.
String computeJwkThumbprint(RSAPublicKey key) {
  final jwk = rsaPublicKeyToJwk(key);
  // Canonical form: alphabetical order of members
  final canonical = '{"e":"${jwk['e']}","kty":"${jwk['kty']}","n":"${jwk['n']}"}';
  final hash = sha256.convert(utf8.encode(canonical));
  return base64Url.encode(hash.bytes).replaceAll('=', '');
}

// ---------------------------------------------------------------------------
// DER encoding helper class (public)
// ---------------------------------------------------------------------------

class DerSequence {
  final List<Uint8List> _elements = [];

  void addInteger(BigInt value) {
    _elements.add(wrapTagAndLength(0x02, _encodeBigInt(value)));
  }

  void addNull() {
    _elements.add(Uint8List.fromList([0x05, 0x00]));
  }

  void addOid(List<int> oid) {
    final bytes = <int>[];
    if (oid.length >= 2) {
      bytes.add(oid[0] * 40 + oid[1]);
      for (int i = 2; i < oid.length; i++) {
        final component = oid[i];
        if (component < 128) {
          bytes.add(component);
        } else {
          final encoded = <int>[];
          int v = component;
          while (v > 0) {
            encoded.insert(0, (v & 0x7f) | (encoded.isEmpty ? 0 : 0x80));
            v >>= 7;
          }
          bytes.addAll(encoded);
        }
      }
    }
    _elements.add(wrapTagAndLength(0x06, Uint8List.fromList(bytes)));
  }

  void addBitString(Uint8List bytes) {
    final data = Uint8List(bytes.length + 1);
    data[0] = 0x00; // no unused bits
    data.setRange(1, data.length, bytes);
    _elements.add(wrapTagAndLength(0x03, data));
  }

  void addOctetString(Uint8List bytes) {
    _elements.add(wrapTagAndLength(0x04, bytes));
  }

  void addUtf8String(String value) {
    _elements.add(wrapTagAndLength(0x0c, Uint8List.fromList(utf8.encode(value))));
  }

  void addUtcTime(DateTime dt) {
    // UTCTime: YYMMDDHHmmSSZ
    final s = '${(dt.year % 100).toString().padLeft(2, '0')}'
        '${dt.month.toString().padLeft(2, '0')}'
        '${dt.day.toString().padLeft(2, '0')}'
        '${dt.hour.toString().padLeft(2, '0')}'
        '${dt.minute.toString().padLeft(2, '0')}'
        '${dt.second.toString().padLeft(2, '0')}Z';
    _elements.add(wrapTagAndLength(0x17, Uint8List.fromList(utf8.encode(s))));
  }

  void addRaw(Uint8List bytes) {
    _elements.add(bytes);
  }

  Uint8List encode() {
    int total = 0;
    for (final e in _elements) {
      total += e.length;
    }
    final content = Uint8List(total);
    int offset = 0;
    for (final e in _elements) {
      content.setRange(offset, offset + e.length, e);
      offset += e.length;
    }
    return wrapTagAndLength(0x30, content);
  }

  static Uint8List wrapTagAndLength(int tag, Uint8List content) {
    final lenBytes = _encodeLength(content.length);
    final result = Uint8List(1 + lenBytes.length + content.length);
    result[0] = tag;
    result.setRange(1, 1 + lenBytes.length, lenBytes);
    result.setRange(1 + lenBytes.length, result.length, content);
    return result;
  }

  static Uint8List _encodeLength(int length) {
    if (length < 128) return Uint8List.fromList([length]);
    final bytes = <int>[];
    int v = length;
    while (v > 0) {
      bytes.insert(0, v & 0xff);
      v >>= 8;
    }
    return Uint8List.fromList([0x80 | bytes.length, ...bytes]);
  }

  static Uint8List _encodeBigInt(BigInt value) {
    if (value == BigInt.zero) return Uint8List.fromList([0x00]);
    final bytes = <int>[];
    BigInt v = value;
    while (v > BigInt.zero) {
      bytes.insert(0, (v & BigInt.from(0xff)).toInt());
      v >>= 8;
    }
    if (bytes.isNotEmpty && (bytes[0] & 0x80) != 0) {
      bytes.insert(0, 0x00);
    }
    return Uint8List.fromList(bytes);
  }
}

// ---------------------------------------------------------------------------
// DER parsing helpers
// ---------------------------------------------------------------------------

/// Parse DER SEQUENCE and return list of raw element bytes.
List<Uint8List> parseDerSequence(Uint8List bytes) {
  final elements = <Uint8List>[];
  if (bytes.isEmpty || bytes[0] != 0x30) return elements;

  int offset = 1;
  int length;
  (length, offset) = parseDerLength(bytes, offset);
  if (offset < 0) return elements;

  final endOffset = offset + length;
  while (offset < endOffset && offset < bytes.length) {
    final elementStart = offset;
    offset++;
    int elemLen;
    (elemLen, offset) = parseDerLength(bytes, offset);
    if (offset < 0) break;
    offset += elemLen;
    elements.add(Uint8List.sublistView(bytes, elementStart, offset));
  }
  return elements;
}

/// Parse DER length. Returns (length, newOffset) or (-1, -1) on error.
(int, int) parseDerLength(Uint8List bytes, int offset) {
  if (offset >= bytes.length) return (-1, -1);
  final first = bytes[offset++];
  if (first < 0x80) return (first, offset);
  final n = first & 0x7f;
  if (n == 0 || offset + n > bytes.length) return (-1, -1);
  int length = 0;
  for (int i = 0; i < n; i++) {
    length = (length << 8) | bytes[offset++];
  }
  return (length, offset);
}

/// Parse a DER INTEGER element and return BigInt, or null on error.
BigInt? parseDerInteger(Uint8List bytes) {
  if (bytes.isEmpty || bytes[0] != 0x02) return null;
  int offset = 1;
  int length;
  (length, offset) = parseDerLength(bytes, offset);
  if (offset < 0 || offset + length > bytes.length) return null;
  final valueBytes = bytes.sublist(offset, offset + length);
  BigInt value = BigInt.zero;
  for (final byte in valueBytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

Uint8List _wrapWithTag(int tag, Uint8List content) {
  return DerSequence.wrapTagAndLength(tag, content);
}

Uint8List _encodePrivateKeyDer(RSAPrivateKey key) {
  final seq = DerSequence();
  seq.addInteger(BigInt.zero); // version
  seq.addInteger(key.modulus!);
  seq.addInteger(key.publicExponent!);
  seq.addInteger(key.privateExponent!);
  seq.addInteger(key.p!);
  seq.addInteger(key.q!);
  seq.addInteger(key.privateExponent! % (key.p! - BigInt.one));
  seq.addInteger(key.privateExponent! % (key.q! - BigInt.one));
  seq.addInteger(key.q!.modInverse(key.p!));
  return seq.encode();
}

RSAPrivateKey _parseRsaPrivateKeyDer(Uint8List bytes) {
  int pos = 0;

  int readLength() {
    int b = bytes[pos++];
    if (b < 0x80) return b;
    int n = b & 0x7f;
    int len = 0;
    for (int i = 0; i < n; i++) {
      len = (len << 8) | bytes[pos++];
    }
    return len;
  }

  BigInt readInteger() {
    if (bytes[pos++] != 0x02) throw FormatException('Expected INTEGER');
    int length = readLength();
    final intBytes = bytes.sublist(pos, pos + length);
    pos += length;
    BigInt value = BigInt.zero;
    for (final byte in intBytes) {
      value = (value << 8) | BigInt.from(byte);
    }
    return value;
  }

  if (bytes[pos++] != 0x30) throw FormatException('Expected SEQUENCE');
  readLength();

  if (bytes[pos] == 0x02) {
    // PKCS#1
    final version = readInteger();
    if (version != BigInt.zero) throw FormatException('Unsupported version');
    final n = readInteger();
    readInteger(); // public exponent (stored in modulus-based key)
    final d = readInteger();
    final p = readInteger();
    final q = readInteger();
    return RSAPrivateKey(n, d, p, q);
  } else {
    // PKCS#8 — skip version, algorithmIdentifier, then unwrap OCTET STRING
    if (bytes[pos++] != 0x02) throw FormatException('Expected INTEGER');
    readLength();
    pos += 1; // skip version byte (usually 0)
    // algorithmIdentifier SEQUENCE
    if (bytes[pos++] != 0x30) throw FormatException('Expected SEQUENCE');
    final algLen = readLength();
    pos += algLen;
    // OCTET STRING containing PKCS#1 key
    if (bytes[pos++] != 0x04) throw FormatException('Expected OCTET STRING');
    readLength();
    return _parseRsaPrivateKeyDer(Uint8List.sublistView(bytes, pos));
  }
}

/// Convert BigInt to minimal unsigned byte representation (big-endian).
Uint8List _bigIntToUnsignedBytes(BigInt value) {
  if (value == BigInt.zero) return Uint8List.fromList([0]);
  final bytes = <int>[];
  BigInt v = value;
  while (v > BigInt.zero) {
    bytes.insert(0, (v & BigInt.from(0xff)).toInt());
    v >>= 8;
  }
  return Uint8List.fromList(bytes);
}
