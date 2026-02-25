/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * XMPP S2S XML builders — stream open/close, features, dialback stanzas
 * for server-to-server federation (XEP-0220 dialback, jabber:server namespace)
 */

import 'xmpp_server_protocol.dart';

// ---------------------------------------------------------------------------
// S2S Namespaces
// ---------------------------------------------------------------------------

class XmppS2sNs {
  static const String server = 'jabber:server';
  static const String dialback = 'jabber:server:dialback';
}

// ---------------------------------------------------------------------------
// S2S XML builders
// ---------------------------------------------------------------------------

class XmppS2sXml {
  /// S2S stream open (outbound: we are initiating)
  static String streamOpen({
    required String from,
    required String to,
    String? id,
    String version = '1.0',
  }) {
    final idAttr = id != null ? " id='$id'" : '';
    return "<?xml version='1.0'?>"
        "<stream:stream "
        "xmlns='${XmppS2sNs.server}' "
        "xmlns:stream='${XmppNs.stream}' "
        "xmlns:db='${XmppS2sNs.dialback}' "
        "from='$from' "
        "to='$to'"
        "$idAttr "
        "version='$version' "
        "xml:lang='en'>";
  }

  /// S2S stream open response (inbound: we are receiving)
  static String streamOpenResponse({
    required String from,
    required String id,
    String version = '1.0',
  }) {
    return "<?xml version='1.0'?>"
        "<stream:stream "
        "xmlns='${XmppS2sNs.server}' "
        "xmlns:stream='${XmppNs.stream}' "
        "xmlns:db='${XmppS2sNs.dialback}' "
        "from='$from' "
        "id='$id' "
        "version='$version' "
        "xml:lang='en'>";
  }

  /// Stream close
  static String streamClose() => '</stream:stream>';

  /// S2S features with STARTTLS + dialback
  static String featuresStartTlsDialback() {
    return '<stream:features>'
        '<starttls xmlns="${XmppNs.tls}"/>'
        '<dialback xmlns="${XmppS2sNs.dialback}"/>'
        '</stream:features>';
  }

  /// S2S features with dialback only (post-TLS)
  static String featuresDialback() {
    return '<stream:features>'
        '<dialback xmlns="${XmppS2sNs.dialback}"/>'
        '</stream:features>';
  }

  /// S2S empty features (fully authenticated)
  static String featuresEmpty() {
    return '<stream:features/>';
  }

  /// Dialback result — sent by initiating server to receiving server
  /// Contains the dialback key for verification
  static String dbResult({
    required String from,
    required String to,
    required String key,
  }) {
    return "<db:result from='$from' to='$to'>$key</db:result>";
  }

  /// Dialback result response — sent by receiving server back to initiating server
  static String dbResultResponse({
    required String from,
    required String to,
    required String type, // 'valid' or 'invalid'
  }) {
    return "<db:result from='$from' to='$to' type='$type'/>";
  }

  /// Dialback verify request — sent by receiving server to authoritative server
  static String dbVerify({
    required String from,
    required String to,
    required String id, // stream ID of the original S2S connection
    required String key,
  }) {
    return "<db:verify from='$from' to='$to' id='$id'>$key</db:verify>";
  }

  /// Dialback verify response
  static String dbVerifyResponse({
    required String from,
    required String to,
    required String id,
    required String type, // 'valid' or 'invalid'
  }) {
    return "<db:verify from='$from' to='$to' id='$id' type='$type'/>";
  }

  /// STARTTLS proceed
  static String tlsProceed() => '<proceed xmlns="${XmppNs.tls}"/>';

  /// STARTTLS failure
  static String tlsFailure() => '<failure xmlns="${XmppNs.tls}"/>';

  /// Stream error
  static String streamError(String condition) {
    return '<stream:error>'
        '<$condition xmlns="urn:ietf:params:xml:ns:xmpp-streams"/>'
        '</stream:error>';
  }
}
