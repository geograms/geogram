/// Represents a single entry in a debt ledger.
///
/// Each entry follows the chat message format and includes a signature
/// that covers all content above it in the ledger file.
library;

import '../../models/chat_message.dart';
import '../../util/chat_format.dart';
import 'currency.dart';

/// Types of debt ledger entries.
enum DebtEntryType {
  create,
  confirm,
  reject,
  witness,
  payment,
  confirmPayment,
  workSession,
  confirmSession,
  statusChange,
  note,
  /// Transfer part of the debt to another creditor
  transfer,
  /// Confirm receiving a transferred debt (new creditor accepts)
  transferReceive,
  /// Debt paid via transfer (creditor received debt from someone else)
  transferPayment,
}

/// Status values for a debt.
enum DebtStatus {
  draft,
  pending,
  open,
  paid,
  expired,
  retired,
  rejected,
  /// Creditor declares debt as uncollectable (debtor unreachable/deceased/other)
  uncollectable,
  /// Debtor declares debt as unpayable (creditor unreachable/deceased/other)
  unpayable,
}

/// Represents a single entry in a debt ledger.
class DebtEntry implements Comparable<DebtEntry> {
  /// Author's callsign
  final String author;

  /// Timestamp in format: YYYY-MM-DD HH:MM_ss
  final String timestamp;

  /// Entry content/description
  final String content;

  /// Entry type
  final DebtEntryType type;

  /// Metadata key-value pairs
  final Map<String, String> metadata;

  /// Whether the signature has been verified
  bool? verified;

  DebtEntry({
    required this.author,
    required this.timestamp,
    required this.content,
    required this.type,
    Map<String, String>? metadata,
    this.verified,
  }) : metadata = metadata ?? {};

  /// Create entry from current time.
  factory DebtEntry.now({
    required String author,
    required String content,
    required DebtEntryType type,
    Map<String, String>? metadata,
  }) {
    final now = DateTime.now();
    final timestamp = ChatFormat.formatTimestamp(now);

    return DebtEntry(
      author: author,
      timestamp: timestamp,
      content: content,
      type: type,
      metadata: metadata,
    );
  }

  /// Parse entry type from string.
  static DebtEntryType? parseType(String? value) {
    if (value == null) return null;
    switch (value.toLowerCase()) {
      case 'create':
        return DebtEntryType.create;
      case 'confirm':
        return DebtEntryType.confirm;
      case 'reject':
        return DebtEntryType.reject;
      case 'witness':
        return DebtEntryType.witness;
      case 'payment':
        return DebtEntryType.payment;
      case 'confirm_payment':
        return DebtEntryType.confirmPayment;
      case 'work_session':
        return DebtEntryType.workSession;
      case 'confirm_session':
        return DebtEntryType.confirmSession;
      case 'status_change':
        return DebtEntryType.statusChange;
      case 'note':
        return DebtEntryType.note;
      case 'transfer':
        return DebtEntryType.transfer;
      case 'transfer_receive':
        return DebtEntryType.transferReceive;
      case 'transfer_payment':
        return DebtEntryType.transferPayment;
      default:
        return null;
    }
  }

  /// Convert entry type to string for storage.
  static String typeToString(DebtEntryType type) {
    switch (type) {
      case DebtEntryType.create:
        return 'create';
      case DebtEntryType.confirm:
        return 'confirm';
      case DebtEntryType.reject:
        return 'reject';
      case DebtEntryType.witness:
        return 'witness';
      case DebtEntryType.payment:
        return 'payment';
      case DebtEntryType.confirmPayment:
        return 'confirm_payment';
      case DebtEntryType.workSession:
        return 'work_session';
      case DebtEntryType.confirmSession:
        return 'confirm_session';
      case DebtEntryType.statusChange:
        return 'status_change';
      case DebtEntryType.note:
        return 'note';
      case DebtEntryType.transfer:
        return 'transfer';
      case DebtEntryType.transferReceive:
        return 'transfer_receive';
      case DebtEntryType.transferPayment:
        return 'transfer_payment';
    }
  }

  /// Parse status from string.
  static DebtStatus? parseStatus(String? value) {
    if (value == null) return null;
    switch (value.toLowerCase()) {
      case 'draft':
        return DebtStatus.draft;
      case 'pending':
        return DebtStatus.pending;
      case 'open':
        return DebtStatus.open;
      case 'paid':
        return DebtStatus.paid;
      case 'expired':
        return DebtStatus.expired;
      case 'retired':
        return DebtStatus.retired;
      case 'rejected':
        return DebtStatus.rejected;
      case 'uncollectable':
        return DebtStatus.uncollectable;
      case 'unpayable':
        return DebtStatus.unpayable;
      default:
        return null;
    }
  }

  /// Convert status to string for storage.
  static String statusToString(DebtStatus status) {
    switch (status) {
      case DebtStatus.draft:
        return 'draft';
      case DebtStatus.pending:
        return 'pending';
      case DebtStatus.open:
        return 'open';
      case DebtStatus.paid:
        return 'paid';
      case DebtStatus.expired:
        return 'expired';
      case DebtStatus.retired:
        return 'retired';
      case DebtStatus.rejected:
        return 'rejected';
      case DebtStatus.uncollectable:
        return 'uncollectable';
      case DebtStatus.unpayable:
        return 'unpayable';
    }
  }

  // ============ Metadata Accessors ============

  /// Get metadata value by key.
  String? getMeta(String key) => metadata[key];

  /// Check if entry has specific metadata.
  bool hasMeta(String key) => metadata.containsKey(key);

  /// Set metadata value.
  void setMeta(String key, String value) {
    metadata[key] = value;
  }

  /// Parse timestamp to DateTime.
  DateTime get dateTime {
    try {
      String datePart = timestamp.substring(0, 10);
      String timePart = timestamp.substring(11);
      List<String> dateParts = datePart.split('-');
      List<String> timeParts = timePart.split(RegExp(r'[_:]'));
      return DateTime(
        int.parse(dateParts[0]),
        int.parse(dateParts[1]),
        int.parse(dateParts[2]),
        int.parse(timeParts[0]),
        int.parse(timeParts[1]),
        int.parse(timeParts[2]),
      );
    } catch (e) {
      return DateTime.now();
    }
  }

  // ============ Signature Fields ============

  /// Author's npub (NOSTR public key).
  String? get npub => getMeta('npub');

  /// Entry signature.
  String? get signature => getMeta('signature');

  /// Check if entry is signed.
  bool get isSigned => hasMeta('signature');

  /// Check if signature is verified.
  bool get isVerified => verified == true;

  // ============ Create Entry Fields ============

  /// Status value (for create/confirm/status_change entries).
  DebtStatus? get status => parseStatus(getMeta('status'));

  /// Creditor callsign.
  String? get creditor => getMeta('creditor');

  /// Creditor npub.
  String? get creditorNpub => getMeta('creditor_npub');

  /// Creditor name.
  String? get creditorName => getMeta('creditor_name');

  /// Debtor callsign.
  String? get debtor => getMeta('debtor');

  /// Debtor npub.
  String? get debtorNpub => getMeta('debtor_npub');

  /// Debtor name.
  String? get debtorName => getMeta('debtor_name');

  /// Original/payment amount.
  double? get amount {
    final value = getMeta('amount');
    return value != null ? double.tryParse(value) : null;
  }

  /// Currency code.
  String? get currency => getMeta('currency');

  /// Get currency object.
  Currency? get currencyObj => Currencies.byCode(currency ?? '');

  /// Due date (YYYY-MM-DD).
  String? get dueDate => getMeta('due_date');

  /// Payment terms.
  String? get terms => getMeta('terms');

  // ============ Payment Fields ============

  /// Remaining balance after payment.
  double? get balance {
    final value = getMeta('balance');
    return value != null ? double.tryParse(value) : null;
  }

  /// Payment method.
  String? get method => getMeta('method');

  // ============ Work Session Fields ============

  /// Duration in minutes.
  int? get duration {
    final value = getMeta('duration');
    return value != null ? int.tryParse(value) : null;
  }

  /// Formatted duration for display.
  String? get formattedDuration {
    final mins = duration;
    return mins != null ? formatDuration(mins) : null;
  }

  /// Work description.
  String? get description => getMeta('description');

  /// Work location.
  String? get location => getMeta('location');

  // ============ Media Fields ============

  /// Attached file name.
  String? get file => getMeta('file');

  /// Attached file SHA1 hash.
  String? get sha1 => getMeta('sha1');

  /// Check if entry has file attachment.
  bool get hasFile => hasMeta('file');

  // ============ Transfer Fields ============

  /// New creditor callsign (for transfer entries).
  String? get newCreditor => getMeta('new_creditor');

  /// New creditor npub (for transfer entries).
  String? get newCreditorNpub => getMeta('new_creditor_npub');

  /// New creditor name (for transfer entries).
  String? get newCreditorName => getMeta('new_creditor_name');

  /// Target debt ID (the new debt created by transfer).
  String? get targetDebtId => getMeta('target_debt_id');

  /// Source debt ID (for transfer_receive entries).
  String? get sourceDebtId => getMeta('source_debt_id');

  /// Original creditor callsign (for transfer_receive entries).
  String? get originalCreditor => getMeta('original_creditor');

  /// Original creditor npub (for transfer_receive entries).
  String? get originalCreditorNpub => getMeta('original_creditor_npub');

  /// Transfer ID that settled this debt (for transfer_payment entries).
  String? get transferDebtId => getMeta('transfer_debt_id');

  // ============ Export ============

  /// Export entry as markdown text.
  String exportAsText() {
    final buffer = StringBuffer();

    // Header
    buffer.writeln('> $timestamp -- $author');

    // Type (always first)
    buffer.writeln('--> type: ${typeToString(type)}');

    // Reserved keys with special ordering
    const reservedKeys = {'type', 'npub', 'signature', 'created_at'};

    // Metadata (excluding reserved)
    for (final entry in metadata.entries) {
      if (reservedKeys.contains(entry.key)) continue;
      buffer.writeln('--> ${entry.key}: ${entry.value}');
    }

    // Content
    if (content.isNotEmpty) {
      buffer.writeln(content);
    }

    // created_at (needed for signature verification)
    if (hasMeta('created_at')) {
      buffer.writeln('--> created_at: ${getMeta('created_at')}');
    }

    // npub comes before signature
    if (hasMeta('npub')) {
      buffer.writeln('--> npub: $npub');
    }

    // Signature must be last
    if (isSigned) {
      buffer.writeln('--> signature: $signature');
    }

    return buffer.toString().trim();
  }

  /// Create DebtEntry from ChatMessage.
  factory DebtEntry.fromChatMessage(ChatMessage message) {
    final typeStr = message.getMeta('type');
    final type = parseType(typeStr) ?? DebtEntryType.note;

    return DebtEntry(
      author: message.author,
      timestamp: message.timestamp,
      content: message.content,
      type: type,
      metadata: Map<String, String>.from(message.metadata),
    );
  }

  /// Convert to ChatMessage for compatibility with existing signing code.
  ChatMessage toChatMessage() {
    final meta = Map<String, String>.from(metadata);
    meta['type'] = typeToString(type);

    return ChatMessage(
      author: author,
      timestamp: timestamp,
      content: content,
      metadata: meta,
    );
  }

  @override
  int compareTo(DebtEntry other) {
    return timestamp.compareTo(other.timestamp);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DebtEntry &&
        other.author == author &&
        other.timestamp == timestamp &&
        other.type == type;
  }

  @override
  int get hashCode => Object.hash(author, timestamp, type);

  @override
  String toString() {
    return 'DebtEntry(type: $type, author: $author, timestamp: $timestamp)';
  }

  /// Create a copy with modified fields.
  DebtEntry copyWith({
    String? author,
    String? timestamp,
    String? content,
    DebtEntryType? type,
    Map<String, String>? metadata,
    bool? verified,
  }) {
    return DebtEntry(
      author: author ?? this.author,
      timestamp: timestamp ?? this.timestamp,
      content: content ?? this.content,
      type: type ?? this.type,
      metadata: metadata ?? Map<String, String>.from(this.metadata),
      verified: verified ?? this.verified,
    );
  }
}
