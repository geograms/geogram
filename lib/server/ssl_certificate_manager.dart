/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared SSL certificate manager — used by both station implementations
 * (PureStationServer/CLI and StationServer/Desktop).
 *
 * Pure Dart implementation — no openssl CLI dependency. Works on all
 * platforms including Android.
 *
 * Handles:
 *   - Let's Encrypt ACME certificate request/renewal (HTTP-01 challenge)
 *   - Self-signed certificate generation for testing
 *   - Account/domain key management (PEM files in {dataDir}/ssl/)
 *   - Auto-renewal timer (12-hour check, 30-day lead time)
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../cli/commands/service_interfaces.dart';
import '../util/rsa_utils.dart' as rsa_utils;
import '../util/rsa_utils.dart' show RSAPrivateKey, RSAPublicKey;

/// Interface a station must implement so the manager can publish/clear
/// HTTP-01 challenge tokens at /.well-known/acme-challenge/{token}.
abstract class AcmeChallengeHandler {
  void setAcmeChallenge(String token, String response);
  void clearAcmeChallenge(String token);
}

class SslCertificateManager {
  StationSettingsReadable _settings;
  final String _sslDir;

  void updateSettings(StationSettingsReadable newSettings) {
    _settings = newSettings;
  }

  StationSettingsReadable get settings => _settings;

  Timer? _renewalTimer;
  final Map<String, String> _challengeResponses = {};

  // Certificate file paths
  String get accountKeyPath => '$_sslDir/account.key';
  String get domainKeyPath => '$_sslDir/domain.key';
  String get certPath => '$_sslDir/certificate.crt';
  String get chainPath => '$_sslDir/certificate-chain.crt';
  String get fullChainPath => '$_sslDir/fullchain.pem';

  // Let's Encrypt ACME endpoints
  static const String productionAcme =
      'https://acme-v02.api.letsencrypt.org/directory';
  static const String stagingAcme =
      'https://acme-staging-v02.api.letsencrypt.org/directory';

  SslCertificateManager(StationSettingsReadable settings, String dataDir)
      : _settings = settings,
        _sslDir = '$dataDir/ssl';

  Future<void> initialize() async {
    await Directory(_sslDir).create(recursive: true);
  }

  void startAutoRenewal() {
    if (!settings.sslAutoRenew) return;
    _renewalTimer?.cancel();
    _renewalTimer = Timer.periodic(const Duration(hours: 12), (_) async {
      await checkAndRenew();
    });
  }

  void stop() {
    _renewalTimer?.cancel();
    _renewalTimer = null;
  }

  bool hasCertificate() => File(certPath).existsSync();

  Future<Map<String, dynamic>> getStatus() async {
    final status = <String, dynamic>{
      'domain': settings.sslDomain ?? '(not set)',
      'email': settings.sslEmail ?? '(not set)',
      'enabled': settings.enableSsl,
      'autoRenew': settings.sslAutoRenew,
      'hasCertificate': hasCertificate(),
    };
    if (hasCertificate()) {
      status.addAll(await _getCertificateInfo());
    }
    return status;
  }

  Future<Map<String, dynamic>> _getCertificateInfo() async {
    try {
      final certFile = File(certPath);
      if (!await certFile.exists()) {
        return {'error': 'Certificate file not found'};
      }

      final certPem = await certFile.readAsString();
      final expiry = rsa_utils.parseCertificateExpiry(certPem);

      if (expiry != null) {
        final daysUntilExpiry = expiry.difference(DateTime.now()).inDays;
        return {
          'expiresAt': expiry.toIso8601String(),
          'daysUntilExpiry': daysUntilExpiry,
          'isValid': daysUntilExpiry > 0,
          'certPath': certPath,
        };
      }
      return {
        'certPath': certPath,
        'status': 'Certificate exists but could not parse expiry',
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<bool> checkAndRenew() async {
    if (!hasCertificate()) return false;
    final info = await _getCertificateInfo();
    final daysUntilExpiry = info['daysUntilExpiry'] as int?;
    if (daysUntilExpiry == null) {
      stdout.writeln(
          '[SSL] Could not determine certificate expiry — skipping auto-renewal check');
      return true;
    }
    stdout.writeln('[SSL] Certificate expires in $daysUntilExpiry days');
    if (daysUntilExpiry <= 30) {
      stdout.writeln('[SSL] Certificate expiring soon — starting auto-renewal...');
      return await renewCertificate(staging: false);
    }
    return true;
  }

  Future<bool> requestCertificate({bool staging = false}) async {
    if (settings.sslDomain == null || settings.sslDomain!.isEmpty) {
      throw Exception('Domain not configured');
    }
    if (settings.sslEmail == null || settings.sslEmail!.isEmpty) {
      throw Exception('Email not configured');
    }

    final acmeUrl = staging ? stagingAcme : productionAcme;

    await _ensureKeyExists(accountKeyPath, 2048);
    await _ensureKeyExists(domainKeyPath, 2048);

    return await _requestWithAcme(
      acmeUrl: acmeUrl,
      domain: settings.sslDomain!,
      email: settings.sslEmail!,
      staging: staging,
    );
  }

  Future<bool> renewCertificate({bool staging = false}) async {
    return await requestCertificate(staging: staging);
  }

  // ---- Pure-Dart key generation ----

  Future<void> _ensureKeyExists(String keyPath, int bits) async {
    if (File(keyPath).existsSync()) return;
    final pair = rsa_utils.generateRsaKeyPair(bits);
    final pem = rsa_utils.encodePrivateKeyPem(pair.privateKey);
    await File(keyPath).writeAsString(pem);
  }

  Future<RSAPrivateKey> _loadAccountKey() async {
    final keyFile = File(accountKeyPath);
    if (!await keyFile.exists()) {
      await _ensureKeyExists(accountKeyPath, 2048);
    }
    final pem = await keyFile.readAsString();
    final key = rsa_utils.decodePrivateKeyPem(pem);
    if (key == null) throw Exception('Failed to parse account key PEM');
    return key;
  }

  Future<RSAPrivateKey> _loadDomainKey() async {
    final keyFile = File(domainKeyPath);
    if (!await keyFile.exists()) {
      await _ensureKeyExists(domainKeyPath, 2048);
    }
    final pem = await keyFile.readAsString();
    final key = rsa_utils.decodePrivateKeyPem(pem);
    if (key == null) throw Exception('Failed to parse domain key PEM');
    return key;
  }

  // Reference to station for HTTP-01 challenge handling
  AcmeChallengeHandler? _challengeHandler;

  void setStationServer(AcmeChallengeHandler handler) {
    _challengeHandler = handler;
  }

  // ---- ACME protocol (pure Dart) ----

  Future<bool> _requestWithAcme({
    required String acmeUrl,
    required String domain,
    required String email,
    required bool staging,
  }) async {
    stdout.writeln('Starting ACME certificate request...');
    stdout.writeln('Domain: $domain');
    stdout.writeln('Email: $email');
    stdout.writeln('Environment: ${staging ? "staging" : "production"}');
    stdout.writeln('');

    try {
      stdout.writeln('[1/7] Fetching ACME directory...');
      final directory = await _fetchAcmeDirectory(acmeUrl);

      stdout.writeln('[2/7] Loading/generating account key...');
      final accountKey = await _loadAccountKey();
      final accountPub = rsa_utils.publicKeyFromPrivate(accountKey);

      stdout.writeln('[3/7] Creating ACME account...');
      final accountUrl = await _createAcmeAccount(
        directory: directory,
        accountKey: accountKey,
        accountPub: accountPub,
        email: email,
      );

      stdout.writeln('[4/7] Creating certificate order...');
      final order = await _createOrder(
        directory: directory,
        accountKey: accountKey,
        accountUrl: accountUrl,
        domain: domain,
      );

      stdout.writeln('[5/7] Completing HTTP-01 challenge...');
      await _completeHttpChallenge(
        directory: directory,
        accountKey: accountKey,
        accountPub: accountPub,
        accountUrl: accountUrl,
        order: order,
        domain: domain,
      );

      stdout.writeln('[6/7] Finalizing order...');
      await _finalizeOrder(
        directory: directory,
        accountKey: accountKey,
        accountUrl: accountUrl,
        order: order,
        domain: domain,
      );

      stdout.writeln('[7/7] Downloading certificate...');
      await _downloadCertificate(
        directory: directory,
        accountKey: accountKey,
        accountUrl: accountUrl,
        order: order,
      );

      stdout.writeln('\nCertificate successfully obtained!');
      return true;
    } catch (e) {
      stdout.writeln('ACME request failed: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _fetchAcmeDirectory(String url) async {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch ACME directory: ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<String> _createAcmeAccount({
    required Map<String, dynamic> directory,
    required RSAPrivateKey accountKey,
    required RSAPublicKey accountPub,
    required String email,
  }) async {
    final newAccountUrl = directory['newAccount'] as String;
    final newNonceUrl = directory['newNonce'] as String;

    final nonceResponse = await http.head(Uri.parse(newNonceUrl));
    final nonce = nonceResponse.headers['replay-nonce'] ?? '';

    final payload = {
      'termsOfServiceAgreed': true,
      'contact': ['mailto:$email'],
    };

    final response = await _signedAcmeRequest(
      url: newAccountUrl,
      payload: payload,
      accountKey: accountKey,
      accountPub: accountPub,
      nonce: nonce,
      useJwk: true,
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception(
          'Failed to create ACME account: ${response.statusCode} ${response.body}');
    }

    final accountUrl = response.headers['location'];
    if (accountUrl == null) throw Exception('No account URL in response');
    return accountUrl;
  }

  Future<Map<String, dynamic>> _createOrder({
    required Map<String, dynamic> directory,
    required RSAPrivateKey accountKey,
    required String accountUrl,
    required String domain,
  }) async {
    final newOrderUrl = directory['newOrder'] as String;
    final newNonceUrl = directory['newNonce'] as String;

    final nonceResponse = await http.head(Uri.parse(newNonceUrl));
    final nonce = nonceResponse.headers['replay-nonce'] ?? '';

    final payload = {
      'identifiers': [
        {'type': 'dns', 'value': domain}
      ],
    };

    final response = await _signedAcmeRequest(
      url: newOrderUrl,
      payload: payload,
      accountKey: accountKey,
      accountUrl: accountUrl,
      nonce: nonce,
    );

    if (response.statusCode != 201) {
      throw Exception(
          'Failed to create order: ${response.statusCode} ${response.body}');
    }

    final order = jsonDecode(response.body) as Map<String, dynamic>;
    order['url'] = response.headers['location'];
    return order;
  }

  Future<void> _completeHttpChallenge({
    required Map<String, dynamic> directory,
    required RSAPrivateKey accountKey,
    required RSAPublicKey accountPub,
    required String accountUrl,
    required Map<String, dynamic> order,
    required String domain,
  }) async {
    final authorizations = order['authorizations'] as List;
    final newNonceUrl = directory['newNonce'] as String;

    for (final authzUrl in authorizations) {
      var nonceResponse = await http.head(Uri.parse(newNonceUrl));
      var nonce = nonceResponse.headers['replay-nonce'] ?? '';

      final authzResponse = await _signedAcmeRequest(
        url: authzUrl as String,
        payload: null,
        accountKey: accountKey,
        accountUrl: accountUrl,
        nonce: nonce,
      );

      final authz = jsonDecode(authzResponse.body) as Map<String, dynamic>;
      final challenges = authz['challenges'] as List;

      final http01 = challenges.firstWhere(
        (c) => c['type'] == 'http-01',
        orElse: () => null,
      );
      if (http01 == null) throw Exception('No HTTP-01 challenge available');

      final token = http01['token'] as String;
      final challengeUrl = http01['url'] as String;

      // Pure-Dart key authorization: token.thumbprint
      final thumbprint = rsa_utils.computeJwkThumbprint(accountPub);
      final keyAuthz = '$token.$thumbprint';

      if (_challengeHandler != null) {
        _challengeHandler!.setAcmeChallenge(token, keyAuthz);
        stdout.writeln('  Challenge token set: $token');
      } else {
        throw Exception('Station server not available for challenge');
      }

      nonceResponse = await http.head(Uri.parse(newNonceUrl));
      nonce = nonceResponse.headers['replay-nonce'] ?? '';

      final challengeResponse = await _signedAcmeRequest(
        url: challengeUrl,
        payload: {},
        accountKey: accountKey,
        accountUrl: accountUrl,
        nonce: nonce,
      );
      if (challengeResponse.statusCode != 200) {
        throw Exception(
            'Challenge request failed: ${challengeResponse.statusCode}');
      }

      stdout.writeln('  Waiting for challenge verification...');
      for (var i = 0; i < 30; i++) {
        await Future.delayed(const Duration(seconds: 2));

        nonceResponse = await http.head(Uri.parse(newNonceUrl));
        nonce = nonceResponse.headers['replay-nonce'] ?? '';

        final statusResponse = await _signedAcmeRequest(
          url: authzUrl as String,
          payload: null,
          accountKey: accountKey,
          accountUrl: accountUrl,
          nonce: nonce,
        );

        final status = jsonDecode(statusResponse.body) as Map<String, dynamic>;
        final authzStatus = status['status'] as String?;

        if (authzStatus == 'valid') {
          stdout.writeln('  Challenge verified!');
          break;
        } else if (authzStatus == 'invalid') {
          throw Exception('Challenge validation failed: ${status['challenges']}');
        }
        stdout.write('.');
      }

      _challengeHandler?.clearAcmeChallenge(token);
    }
  }

  Future<void> _finalizeOrder({
    required Map<String, dynamic> directory,
    required RSAPrivateKey accountKey,
    required String accountUrl,
    required Map<String, dynamic> order,
    required String domain,
  }) async {
    final finalizeUrl = order['finalize'] as String;
    final newNonceUrl = directory['newNonce'] as String;

    final domainKey = await _loadDomainKey();
    final domainPub = rsa_utils.publicKeyFromPrivate(domainKey);

    final csrDer = rsa_utils.generateCsrDer(domainKey, domainPub, domain);
    final csrB64 = base64Url.encode(csrDer).replaceAll('=', '');

    final nonceResponse = await http.head(Uri.parse(newNonceUrl));
    final nonce = nonceResponse.headers['replay-nonce'] ?? '';

    final response = await _signedAcmeRequest(
      url: finalizeUrl,
      payload: {'csr': csrB64},
      accountKey: accountKey,
      accountUrl: accountUrl,
      nonce: nonce,
    );

    if (response.statusCode != 200) {
      throw Exception(
          'Failed to finalize order: ${response.statusCode} ${response.body}');
    }

    final updatedOrder = jsonDecode(response.body) as Map<String, dynamic>;
    order.addAll(updatedOrder);

    stdout.writeln('  Waiting for certificate issuance...');
    final orderUrl = order['url'] as String;

    for (var i = 0; i < 30; i++) {
      await Future.delayed(const Duration(seconds: 2));

      final checkNonceResponse = await http.head(Uri.parse(newNonceUrl));
      final checkNonce = checkNonceResponse.headers['replay-nonce'] ?? '';

      final statusResponse = await _signedAcmeRequest(
        url: orderUrl,
        payload: null,
        accountKey: accountKey,
        accountUrl: accountUrl,
        nonce: checkNonce,
      );

      final status = jsonDecode(statusResponse.body) as Map<String, dynamic>;
      final orderStatus = status['status'] as String?;

      if (orderStatus == 'valid') {
        order['certificate'] = status['certificate'];
        stdout.writeln('  Certificate ready!');
        return;
      } else if (orderStatus == 'invalid') {
        throw Exception('Order became invalid');
      }
    }
    throw Exception('Timeout waiting for certificate');
  }

  Future<void> _downloadCertificate({
    required Map<String, dynamic> directory,
    required RSAPrivateKey accountKey,
    required String accountUrl,
    required Map<String, dynamic> order,
  }) async {
    final certUrl = order['certificate'] as String?;
    if (certUrl == null) throw Exception('No certificate URL in order');

    final newNonceUrl = directory['newNonce'] as String;
    final nonceResponse = await http.head(Uri.parse(newNonceUrl));
    final nonce = nonceResponse.headers['replay-nonce'] ?? '';

    final response = await _signedAcmeRequest(
      url: certUrl,
      payload: null,
      accountKey: accountKey,
      accountUrl: accountUrl,
      nonce: nonce,
      accept: 'application/pem-certificate-chain',
    );

    if (response.statusCode != 200) {
      throw Exception(
          'Failed to download certificate: ${response.statusCode}');
    }

    final certChain = response.body;
    await File(fullChainPath).writeAsString(certChain);
    await File(certPath).writeAsString(certChain);
    stdout.writeln('  Certificate saved to: $fullChainPath');
  }

  // ---- Pure-Dart ACME signing ----

  Future<http.Response> _signedAcmeRequest({
    required String url,
    required dynamic payload,
    required RSAPrivateKey accountKey,
    required String nonce,
    String? accountUrl,
    RSAPublicKey? accountPub,
    bool useJwk = false,
    String accept = 'application/json',
  }) async {
    final protected = <String, dynamic>{
      'alg': 'RS256',
      'nonce': nonce,
      'url': url,
    };

    if (useJwk) {
      final pub = accountPub ?? rsa_utils.publicKeyFromPrivate(accountKey);
      protected['jwk'] = rsa_utils.rsaPublicKeyToJwk(pub);
    } else {
      protected['kid'] = accountUrl;
    }

    final protectedB64 = base64Url
        .encode(utf8.encode(jsonEncode(protected)))
        .replaceAll('=', '');

    String payloadB64;
    if (payload == null) {
      payloadB64 = '';
    } else {
      payloadB64 = base64Url
          .encode(utf8.encode(jsonEncode(payload)))
          .replaceAll('=', '');
    }

    final signingInput = '$protectedB64.$payloadB64';
    final sigBytes = rsa_utils.rsaSign(utf8.encode(signingInput), accountKey);
    final signature = base64Url.encode(sigBytes).replaceAll('=', '');

    final body = jsonEncode({
      'protected': protectedB64,
      'payload': payloadB64,
      'signature': signature,
    });

    return await http.post(
      Uri.parse(url),
      headers: {
        'Content-Type': 'application/jose+json',
        'Accept': accept,
      },
      body: body,
    );
  }

  // ---- Challenge response storage (legacy API kept for callers) ----

  String? getChallengeResponse(String token) => _challengeResponses[token];

  void setChallengeResponse(String token, String response) {
    _challengeResponses[token] = response;
  }

  void clearChallengeResponse(String token) {
    _challengeResponses.remove(token);
  }

  // ---- Self-signed certificate (pure Dart) ----

  Future<bool> generateSelfSigned(String domain) async {
    final pair = rsa_utils.generateRsaKeyPair(2048);
    final keyPem = rsa_utils.encodePrivateKeyPem(pair.privateKey);
    await File(domainKeyPath).writeAsString(keyPem);

    final certDer = rsa_utils.generateSelfSignedCertDer(
        pair.privateKey, pair.publicKey, domain);
    final certPem = rsa_utils.encodeCertPem(certDer);
    await File(certPath).writeAsString(certPem);
    await File(fullChainPath).writeAsString(certPem);
    return true;
  }
}
