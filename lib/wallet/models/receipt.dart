/// Receipt model for recording spontaneous payments.
///
/// Unlike debts which track ongoing obligations, receipts are records
/// of payments that have already occurred. They provide cryptographic
/// evidence of a transaction at a specific time and place.
library;

import '../../util/chat_format.dart';
import 'currency.dart';

/// Represents a payment receipt.
///
/// Receipts record completed transactions with cryptographic signatures
/// for non-repudiation. Both payer and payee can sign to acknowledge
/// the transaction occurred.
class Receipt {
  /// Unique identifier (format: receipt_YYYYMMDD_XXXXXX)
  final String id;

  /// Timestamp when the payment occurred
  final DateTime timestamp;

  /// Payer information
  final ReceiptParty payer;

  /// Payee (recipient) information
  final ReceiptParty payee;

  /// Amount paid
  final double amount;

  /// Currency code
  final String currency;

  /// Description of what the payment was for
  final String description;

  /// Optional detailed notes
  final String? notes;

  /// Location where payment occurred (if recorded)
  final ReceiptLocation? location;

  /// Payment method (cash, transfer, crypto, etc.)
  final String? paymentMethod;

  /// Optional reference number (invoice, order, etc.)
  final String? reference;

  /// Attached files (photos, documents)
  final List<ReceiptAttachment> attachments;

  /// Payer's signature (signs the receipt content)
  final ReceiptSignature? payerSignature;

  /// Payee's signature (acknowledges receipt of payment)
  final ReceiptSignature? payeeSignature;

  /// Witness signatures (optional third-party attestation)
  final List<ReceiptSignature> witnessSignatures;

  /// Tags for organization
  final List<String> tags;

  /// Receipt status
  final ReceiptStatus status;

  Receipt({
    required this.id,
    required this.timestamp,
    required this.payer,
    required this.payee,
    required this.amount,
    required this.currency,
    required this.description,
    this.notes,
    this.location,
    this.paymentMethod,
    this.reference,
    this.attachments = const [],
    this.payerSignature,
    this.payeeSignature,
    this.witnessSignatures = const [],
    this.tags = const [],
    this.status = ReceiptStatus.draft,
  });

  /// Generate a new receipt ID.
  static String generateId() {
    final now = DateTime.now();
    final date =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final random = DateTime.now().microsecondsSinceEpoch.toRadixString(36).substring(0, 6).toUpperCase();
    return 'receipt_${date}_$random';
  }

  /// Get the currency object.
  Currency? get currencyObj => Currencies.byCode(currency);

  /// Format the amount with currency.
  String get formattedAmount {
    final curr = currencyObj;
    if (curr != null) {
      return curr.format(amount);
    }
    return '${amount.toStringAsFixed(2)} $currency';
  }

  /// Format the timestamp.
  String get formattedTimestamp {
    return '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')} '
        '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
  }

  /// Check if both parties have signed.
  bool get isFullySigned => payerSignature != null && payeeSignature != null;

  /// Check if at least one party has signed.
  bool get hasSignature => payerSignature != null || payeeSignature != null;

  /// Create a copy with updated fields.
  Receipt copyWith({
    String? id,
    DateTime? timestamp,
    ReceiptParty? payer,
    ReceiptParty? payee,
    double? amount,
    String? currency,
    String? description,
    String? notes,
    ReceiptLocation? location,
    String? paymentMethod,
    String? reference,
    List<ReceiptAttachment>? attachments,
    ReceiptSignature? payerSignature,
    ReceiptSignature? payeeSignature,
    List<ReceiptSignature>? witnessSignatures,
    List<String>? tags,
    ReceiptStatus? status,
  }) {
    return Receipt(
      id: id ?? this.id,
      timestamp: timestamp ?? this.timestamp,
      payer: payer ?? this.payer,
      payee: payee ?? this.payee,
      amount: amount ?? this.amount,
      currency: currency ?? this.currency,
      description: description ?? this.description,
      notes: notes ?? this.notes,
      location: location ?? this.location,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      reference: reference ?? this.reference,
      attachments: attachments ?? this.attachments,
      payerSignature: payerSignature ?? this.payerSignature,
      payeeSignature: payeeSignature ?? this.payeeSignature,
      witnessSignatures: witnessSignatures ?? this.witnessSignatures,
      tags: tags ?? this.tags,
      status: status ?? this.status,
    );
  }

  /// Convert to markdown format for storage.
  String toMarkdown() {
    final buffer = StringBuffer();

    // Header
    buffer.writeln('# $id: $description');
    buffer.writeln();

    // Main receipt entry
    buffer.writeln('> ${ChatFormat.formatTimestamp(timestamp)} -- ${payer.callsign}');
    buffer.writeln('--> type: receipt');
    buffer.writeln('--> status: ${status.name}');
    buffer.writeln('--> payer: ${payer.callsign}');
    buffer.writeln('--> payer_npub: ${payer.npub}');
    if (payer.name != null) {
      buffer.writeln('--> payer_name: ${payer.name}');
    }
    buffer.writeln('--> payee: ${payee.callsign}');
    buffer.writeln('--> payee_npub: ${payee.npub}');
    if (payee.name != null) {
      buffer.writeln('--> payee_name: ${payee.name}');
    }
    buffer.writeln('--> amount: $amount');
    buffer.writeln('--> currency: $currency');

    if (paymentMethod != null) {
      buffer.writeln('--> method: $paymentMethod');
    }
    if (reference != null) {
      buffer.writeln('--> reference: $reference');
    }
    if (location != null) {
      buffer.writeln('--> lat: ${location!.latitude}');
      buffer.writeln('--> lon: ${location!.longitude}');
      if (location!.accuracy != null) {
        buffer.writeln('--> accuracy: ${location!.accuracy}');
      }
      if (location!.placeName != null) {
        buffer.writeln('--> place: ${location!.placeName}');
      }
    }
    if (tags.isNotEmpty) {
      buffer.writeln('--> tags: ${tags.join(', ')}');
    }

    // Attachments
    for (final attachment in attachments) {
      buffer.writeln('--> file: ${attachment.filename}');
      buffer.writeln('--> sha1: ${attachment.sha1}');
    }

    // Description and notes
    buffer.writeln(description);
    if (notes != null && notes!.isNotEmpty) {
      buffer.writeln();
      buffer.writeln(notes);
    }

    // Payer signature
    if (payerSignature != null) {
      buffer.writeln('--> npub: ${payerSignature!.npub}');
      buffer.writeln('--> signature: ${payerSignature!.signature}');
    }

    buffer.writeln();

    // Payee confirmation entry
    if (payeeSignature != null) {
      buffer.writeln('> ${ChatFormat.formatTimestamp(payeeSignature!.timestamp)} -- ${payee.callsign}');
      buffer.writeln('--> type: confirm_receipt');
      buffer.writeln('I confirm receiving this payment.');
      buffer.writeln('--> npub: ${payeeSignature!.npub}');
      buffer.writeln('--> signature: ${payeeSignature!.signature}');
      buffer.writeln();
    }

    // Witness entries
    for (final witness in witnessSignatures) {
      buffer.writeln('> ${ChatFormat.formatTimestamp(witness.timestamp)} -- ${witness.callsign ?? 'WITNESS'}');
      buffer.writeln('--> type: witness');
      buffer.writeln('I witness this transaction.');
      buffer.writeln('--> npub: ${witness.npub}');
      buffer.writeln('--> signature: ${witness.signature}');
      buffer.writeln();
    }

    return buffer.toString();
  }

  /// Convert to JSON.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'timestamp': timestamp.toIso8601String(),
      'payer': payer.toJson(),
      'payee': payee.toJson(),
      'amount': amount,
      'currency': currency,
      'description': description,
      'notes': notes,
      'location': location?.toJson(),
      'payment_method': paymentMethod,
      'reference': reference,
      'attachments': attachments.map((a) => a.toJson()).toList(),
      'payer_signature': payerSignature?.toJson(),
      'payee_signature': payeeSignature?.toJson(),
      'witness_signatures': witnessSignatures.map((w) => w.toJson()).toList(),
      'tags': tags,
      'status': status.name,
    };
  }

  /// Create from JSON.
  factory Receipt.fromJson(Map<String, dynamic> json) {
    return Receipt(
      id: json['id'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      payer: ReceiptParty.fromJson(json['payer'] as Map<String, dynamic>),
      payee: ReceiptParty.fromJson(json['payee'] as Map<String, dynamic>),
      amount: (json['amount'] as num).toDouble(),
      currency: json['currency'] as String,
      description: json['description'] as String,
      notes: json['notes'] as String?,
      location: json['location'] != null
          ? ReceiptLocation.fromJson(json['location'] as Map<String, dynamic>)
          : null,
      paymentMethod: json['payment_method'] as String?,
      reference: json['reference'] as String?,
      attachments: (json['attachments'] as List?)
              ?.map((a) => ReceiptAttachment.fromJson(a as Map<String, dynamic>))
              .toList() ??
          [],
      payerSignature: json['payer_signature'] != null
          ? ReceiptSignature.fromJson(json['payer_signature'] as Map<String, dynamic>)
          : null,
      payeeSignature: json['payee_signature'] != null
          ? ReceiptSignature.fromJson(json['payee_signature'] as Map<String, dynamic>)
          : null,
      witnessSignatures: (json['witness_signatures'] as List?)
              ?.map((w) => ReceiptSignature.fromJson(w as Map<String, dynamic>))
              .toList() ??
          [],
      tags: (json['tags'] as List?)?.cast<String>() ?? [],
      status: ReceiptStatus.fromString(json['status'] as String?),
    );
  }

  /// Parse receipt from markdown content.
  static Receipt? parseFromMarkdown(String content) {
    final lines = content.split('\n');
    if (lines.isEmpty) return null;

    String? id;
    String? description;
    DateTime? timestamp;
    ReceiptParty? payer;
    ReceiptParty? payee;
    double? amount;
    String? currency;
    String? notes;
    ReceiptLocation? location;
    String? paymentMethod;
    String? reference;
    final attachments = <ReceiptAttachment>[];
    ReceiptSignature? payerSignature;
    ReceiptSignature? payeeSignature;
    final witnessSignatures = <ReceiptSignature>[];
    final tags = <String>[];
    var status = ReceiptStatus.draft;

    // Temporary variables for parsing
    String? payerCallsign;
    String? payerNpub;
    String? payerName;
    String? payeeCallsign;
    String? payeeNpub;
    String? payeeName;
    double? lat;
    double? lon;
    double? accuracy;
    String? placeName;
    String? currentFile;
    String? currentType;
    String? currentNpub;
    String? currentCallsign;
    DateTime? currentEntryTime;

    final headerRegex = RegExp(r'^# (receipt_\d+_\w+): (.+)$');
    final entryHeaderRegex = RegExp(r'^> (\d{4}-\d{2}-\d{2} \d{2}:\d{2}_\d{2}) -- (\w+)$');
    final metaRegex = RegExp(r'^--> (\w+): (.+)$');

    for (final line in lines) {
      // Parse header
      final headerMatch = headerRegex.firstMatch(line);
      if (headerMatch != null) {
        id = headerMatch.group(1);
        description = headerMatch.group(2);
        continue;
      }

      // Parse entry header
      final entryMatch = entryHeaderRegex.firstMatch(line);
      if (entryMatch != null) {
        // Save previous entry if needed
        if (currentType == 'confirm_receipt' && currentNpub != null) {
          // This was handled below
        }

        final timeStr = entryMatch.group(1)!.replaceAll('_', ':');
        currentEntryTime = DateTime.tryParse(timeStr.replaceFirst(' ', 'T'));
        currentCallsign = entryMatch.group(2);
        currentType = null;
        currentNpub = null;
        continue;
      }

      // Parse metadata
      final metaMatch = metaRegex.firstMatch(line);
      if (metaMatch != null) {
        final key = metaMatch.group(1)!;
        final value = metaMatch.group(2)!;

        switch (key) {
          case 'type':
            currentType = value;
            break;
          case 'status':
            status = ReceiptStatus.fromString(value);
            break;
          case 'payer':
            payerCallsign = value;
            break;
          case 'payer_npub':
            payerNpub = value;
            break;
          case 'payer_name':
            payerName = value;
            break;
          case 'payee':
            payeeCallsign = value;
            break;
          case 'payee_npub':
            payeeNpub = value;
            break;
          case 'payee_name':
            payeeName = value;
            break;
          case 'amount':
            amount = double.tryParse(value);
            break;
          case 'currency':
            currency = value;
            break;
          case 'method':
            paymentMethod = value;
            break;
          case 'reference':
            reference = value;
            break;
          case 'lat':
            lat = double.tryParse(value);
            break;
          case 'lon':
            lon = double.tryParse(value);
            break;
          case 'accuracy':
            accuracy = double.tryParse(value);
            break;
          case 'place':
            placeName = value;
            break;
          case 'tags':
            tags.addAll(value.split(',').map((t) => t.trim()));
            break;
          case 'file':
            currentFile = value;
            break;
          case 'sha1':
            if (currentFile != null) {
              attachments.add(ReceiptAttachment(
                filename: currentFile!,
                sha1: value,
              ));
              currentFile = null;
            }
            break;
          case 'npub':
            currentNpub = value;
            break;
          case 'signature':
            if (currentNpub != null && currentEntryTime != null) {
              final sig = ReceiptSignature(
                npub: currentNpub!,
                signature: value,
                timestamp: currentEntryTime!,
                callsign: currentCallsign,
              );

              if (currentType == 'receipt') {
                payerSignature = sig;
                timestamp ??= currentEntryTime;
              } else if (currentType == 'confirm_receipt') {
                payeeSignature = sig;
              } else if (currentType == 'witness') {
                witnessSignatures.add(sig);
              }
            }
            break;
        }
        continue;
      }

      // Non-metadata lines could be notes
      if (line.isNotEmpty &&
          !line.startsWith('#') &&
          !line.startsWith('>') &&
          !line.startsWith('-->') &&
          currentType == 'receipt' &&
          line != description) {
        if (notes == null) {
          notes = line;
        } else {
          notes = '$notes\n$line';
        }
      }
    }

    // Build location if we have coordinates
    if (lat != null && lon != null) {
      location = ReceiptLocation(
        latitude: lat,
        longitude: lon,
        accuracy: accuracy,
        placeName: placeName,
      );
    }

    // Build parties
    if (payerCallsign != null && payerNpub != null) {
      payer = ReceiptParty(
        callsign: payerCallsign,
        npub: payerNpub,
        name: payerName,
      );
    }
    if (payeeCallsign != null && payeeNpub != null) {
      payee = ReceiptParty(
        callsign: payeeCallsign,
        npub: payeeNpub,
        name: payeeName,
      );
    }

    // Validate required fields
    if (id == null ||
        description == null ||
        timestamp == null ||
        payer == null ||
        payee == null ||
        amount == null ||
        currency == null) {
      return null;
    }

    return Receipt(
      id: id,
      timestamp: timestamp,
      payer: payer,
      payee: payee,
      amount: amount,
      currency: currency,
      description: description,
      notes: notes,
      location: location,
      paymentMethod: paymentMethod,
      reference: reference,
      attachments: attachments,
      payerSignature: payerSignature,
      payeeSignature: payeeSignature,
      witnessSignatures: witnessSignatures,
      tags: tags,
      status: status,
    );
  }
}

/// Party information in a receipt.
class ReceiptParty {
  /// Callsign (short identifier)
  final String callsign;

  /// NOSTR public key (npub)
  final String npub;

  /// Human-readable name (optional)
  final String? name;

  ReceiptParty({
    required this.callsign,
    required this.npub,
    this.name,
  });

  /// Display name (name if available, otherwise callsign)
  String get displayName => name ?? callsign;

  Map<String, dynamic> toJson() {
    return {
      'callsign': callsign,
      'npub': npub,
      'name': name,
    };
  }

  factory ReceiptParty.fromJson(Map<String, dynamic> json) {
    return ReceiptParty(
      callsign: json['callsign'] as String,
      npub: json['npub'] as String,
      name: json['name'] as String?,
    );
  }
}

/// Location information for a receipt.
class ReceiptLocation {
  final double latitude;
  final double longitude;
  final double? accuracy;
  final String? placeName;

  ReceiptLocation({
    required this.latitude,
    required this.longitude,
    this.accuracy,
    this.placeName,
  });

  /// Format as coordinates string.
  String get coordinates =>
      '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';

  Map<String, dynamic> toJson() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': accuracy,
      'place_name': placeName,
    };
  }

  factory ReceiptLocation.fromJson(Map<String, dynamic> json) {
    return ReceiptLocation(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      accuracy: (json['accuracy'] as num?)?.toDouble(),
      placeName: json['place_name'] as String?,
    );
  }
}

/// File attachment with integrity hash.
class ReceiptAttachment {
  final String filename;
  final String sha1;
  final String? mimeType;

  ReceiptAttachment({
    required this.filename,
    required this.sha1,
    this.mimeType,
  });

  Map<String, dynamic> toJson() {
    return {
      'filename': filename,
      'sha1': sha1,
      'mime_type': mimeType,
    };
  }

  factory ReceiptAttachment.fromJson(Map<String, dynamic> json) {
    return ReceiptAttachment(
      filename: json['filename'] as String,
      sha1: json['sha1'] as String,
      mimeType: json['mime_type'] as String?,
    );
  }
}

/// Cryptographic signature on a receipt.
class ReceiptSignature {
  final String npub;
  final String signature;
  final DateTime timestamp;
  final String? callsign;

  ReceiptSignature({
    required this.npub,
    required this.signature,
    required this.timestamp,
    this.callsign,
  });

  Map<String, dynamic> toJson() {
    return {
      'npub': npub,
      'signature': signature,
      'timestamp': timestamp.toIso8601String(),
      'callsign': callsign,
    };
  }

  factory ReceiptSignature.fromJson(Map<String, dynamic> json) {
    return ReceiptSignature(
      npub: json['npub'] as String,
      signature: json['signature'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      callsign: json['callsign'] as String?,
    );
  }
}

/// Receipt status.
enum ReceiptStatus {
  /// Created locally, not yet signed
  draft,

  /// Signed by payer only
  issued,

  /// Signed by both payer and payee
  confirmed,

  /// Sent to counterparty, awaiting their signature
  pending;

  static ReceiptStatus fromString(String? value) {
    switch (value?.toLowerCase()) {
      case 'draft':
        return ReceiptStatus.draft;
      case 'issued':
        return ReceiptStatus.issued;
      case 'confirmed':
        return ReceiptStatus.confirmed;
      case 'pending':
        return ReceiptStatus.pending;
      default:
        return ReceiptStatus.draft;
    }
  }
}

/// Payment methods for receipts.
class PaymentMethods {
  PaymentMethods._();

  static const cash = 'cash';
  static const bankTransfer = 'bank_transfer';
  static const card = 'card';
  static const crypto = 'crypto';
  static const check = 'check';
  static const mobilePayment = 'mobile_payment';
  static const barter = 'barter';
  static const other = 'other';

  static const List<String> all = [
    cash,
    bankTransfer,
    card,
    crypto,
    check,
    mobilePayment,
    barter,
    other,
  ];

  /// Get display name for a payment method.
  static String displayName(String method) {
    switch (method) {
      case cash:
        return 'Cash';
      case bankTransfer:
        return 'Bank Transfer';
      case card:
        return 'Card';
      case crypto:
        return 'Cryptocurrency';
      case check:
        return 'Check';
      case mobilePayment:
        return 'Mobile Payment';
      case barter:
        return 'Barter/Trade';
      case other:
        return 'Other';
      default:
        return method;
    }
  }
}
