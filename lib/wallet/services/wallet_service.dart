/// Main service for managing wallet/debt operations.
///
/// Handles debt CRUD, folder management, and signature verification.
/// Uses the same patterns as InventoryService.
library;

import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as path;

import '../models/debt_entry.dart';
import '../models/debt_ledger.dart';
import '../models/debt_summary.dart';
import '../models/payment_schedule.dart';
import '../models/receipt.dart';
import '../utils/default_terms.dart';
import '../../models/profile.dart';
import '../../services/signing_service.dart';
import '../../services/log_service.dart';
import '../../util/chat_format.dart';
import '../../util/nostr_crypto.dart';
import '../../util/nostr_event.dart';

/// Main service for managing wallet operations
class WalletService {
  static final WalletService _instance = WalletService._internal();
  factory WalletService() => _instance;
  WalletService._internal();

  String? _basePath;

  /// Stream controller for wallet changes
  final _changesController = StreamController<WalletChange>.broadcast();

  /// Stream of wallet changes
  Stream<WalletChange> get changes => _changesController.stream;

  /// Check if the service is initialized
  bool get isInitialized => _basePath != null;

  /// Get the current app path
  String? get currentPath => _basePath;

  /// Initialize the service with an app path
  Future<void> initializeApp(String appPath) async {
    _basePath = appPath;

    // Ensure debts directory exists
    final debtsDir = Directory(path.join(_basePath!, 'debts'));
    if (!await debtsDir.exists()) {
      await debtsDir.create(recursive: true);
    }

    // Ensure receipts directory exists
    final receiptsDir = Directory(path.join(_basePath!, 'receipts'));
    if (!await receiptsDir.exists()) {
      await receiptsDir.create(recursive: true);
    }

    // Ensure requests directory exists
    final requestsDir = Directory(path.join(_basePath!, 'requests'));
    if (!await requestsDir.exists()) {
      await requestsDir.create(recursive: true);
    }

    LogService().log('WalletService: Initialized with path $appPath');
  }

  /// Reset the service (for switching collections)
  void reset() {
    _basePath = null;
  }

  // ============ Folder Operations ============

  /// Get all folders in the debts directory
  Future<List<String>> getFolders() async {
    if (_basePath == null) return [];

    try {
      final debtsDir = Directory(path.join(_basePath!, 'debts'));
      if (!await debtsDir.exists()) return [];

      final folders = <String>[];
      await for (final entity in debtsDir.list()) {
        if (entity is Directory) {
          final name = path.basename(entity.path);
          if (!name.startsWith('.') && name != 'media') {
            folders.add(name);
          }
        }
      }
      folders.sort();
      return folders;
    } catch (e) {
      LogService().log('WalletService: Error listing folders: $e');
      return [];
    }
  }

  /// Create a new folder
  Future<bool> createFolder(String folderName) async {
    if (_basePath == null) return false;

    try {
      final folderDir = Directory(path.join(_basePath!, 'debts', folderName));
      await folderDir.create(recursive: true);

      // Create media subdirectory
      final mediaDir = Directory(path.join(folderDir.path, 'media'));
      await mediaDir.create(recursive: true);

      _notifyChange(WalletChangeType.folderCreated, folderPath: folderName);
      return true;
    } catch (e) {
      LogService().log('WalletService: Error creating folder: $e');
      return false;
    }
  }

  /// Delete a folder
  Future<bool> deleteFolder(String folderName) async {
    if (_basePath == null) return false;

    try {
      final folderDir = Directory(path.join(_basePath!, 'debts', folderName));
      if (await folderDir.exists()) {
        await folderDir.delete(recursive: true);
      }
      _notifyChange(WalletChangeType.folderDeleted, folderPath: folderName);
      return true;
    } catch (e) {
      LogService().log('WalletService: Error deleting folder: $e');
      return false;
    }
  }

  /// Rename a folder
  Future<bool> renameFolder(String oldName, String newName) async {
    if (_basePath == null) return false;
    if (oldName == newName) return true;

    try {
      final oldDir = Directory(path.join(_basePath!, 'debts', oldName));
      if (!await oldDir.exists()) return false;

      final newDir = Directory(path.join(_basePath!, 'debts', newName));
      if (await newDir.exists()) {
        LogService().log('WalletService: Cannot rename, folder $newName already exists');
        return false;
      }

      await oldDir.rename(newDir.path);
      _notifyChange(WalletChangeType.folderRenamed, folderPath: newName);
      return true;
    } catch (e) {
      LogService().log('WalletService: Error renaming folder: $e');
      return false;
    }
  }

  // ============ Debt Operations ============

  /// List all debts in a folder (or root if folderPath is null)
  Future<List<DebtSummary>> listDebts({String? folderPath}) async {
    if (_basePath == null) return [];

    try {
      final searchPath = folderPath != null
          ? path.join(_basePath!, 'debts', folderPath)
          : path.join(_basePath!, 'debts');

      final dir = Directory(searchPath);
      if (!await dir.exists()) return [];

      final summaries = <DebtSummary>[];
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.md')) {
          try {
            final ledger = await _readLedgerFile(entity.path);
            if (ledger != null) {
              summaries.add(DebtSummary.fromLedger(ledger));
            }
          } catch (e) {
            LogService().log('WalletService: Error reading debt ${entity.path}: $e');
          }
        }
      }

      // Sort by modified date, newest first
      summaries.sort((a, b) => (b.modifiedAt ?? DateTime(0)).compareTo(a.modifiedAt ?? DateTime(0)));
      return summaries;
    } catch (e) {
      LogService().log('WalletService: Error listing debts: $e');
      return [];
    }
  }

  /// List all debts recursively
  Future<List<DebtSummary>> listAllDebts() async {
    if (_basePath == null) return [];

    final allDebts = <DebtSummary>[];

    // Get debts at root level
    allDebts.addAll(await listDebts());

    // Get debts in each folder
    final folders = await getFolders();
    for (final folder in folders) {
      allDebts.addAll(await listDebts(folderPath: folder));
    }

    return allDebts;
  }

  /// Get a debt ledger by ID
  Future<DebtLedger?> getDebt(String debtId, {String? folderPath}) async {
    if (_basePath == null) return null;

    final filePath = _buildDebtPath(debtId, folderPath: folderPath);
    return _readLedgerFile(filePath);
  }

  /// Find a debt by ID (searches all folders)
  Future<DebtLedger?> findDebt(String debtId) async {
    if (_basePath == null) return null;

    // Try root first
    var ledger = await getDebt(debtId);
    if (ledger != null) return ledger;

    // Search folders
    final folders = await getFolders();
    for (final folder in folders) {
      ledger = await getDebt(debtId, folderPath: folder);
      if (ledger != null) return ledger;
    }

    return null;
  }

  /// Create a new debt (draft, not yet sent to counterparty)
  ///
  /// [description] - Human-readable description of the debt
  /// [content] - Additional notes (default terms are always included)
  /// [additionalTerms] - Custom terms to add beyond the standard terms
  /// [governingJurisdiction] - Override default jurisdiction (creditor's location)
  /// [includeTerms] - Whether to include standard legal terms (default: true)
  /// [annualInterestRate] - Annual interest rate as percentage (e.g., 5.0 for 5%)
  /// [numberOfInstallments] - Number of payment installments (default: 1 for single payment)
  /// [paymentIntervalDays] - Days between payments (default: 30 for monthly)
  Future<DebtLedger?> createDebt({
    required String description,
    required String creditor,
    required String creditorNpub,
    String? creditorName,
    required String debtor,
    required String debtorNpub,
    String? debtorName,
    required double amount,
    required String currency,
    String? dueDate,
    String? terms,
    String? content,
    String? additionalTerms,
    String? governingJurisdiction,
    bool includeTerms = true,
    double? annualInterestRate,
    int numberOfInstallments = 1,
    int paymentIntervalDays = 30,
    String? folderPath,
    Profile? profile,
  }) async {
    if (_basePath == null) return null;

    // Generate debt ID
    final now = DateTime.now();
    final dateStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final randomId = _generateRandomId(6);
    final debtId = 'debt_${dateStr}_$randomId';

    // Create the ledger
    final ledger = DebtLedger(
      id: debtId,
      description: description,
      filePath: _buildDebtPath(debtId, folderPath: folderPath),
    );

    // Generate payment schedule if interest or installments specified
    PaymentSchedule? paymentSchedule;
    DateTime? firstPaymentDate;

    if (dueDate != null) {
      firstPaymentDate = DateTime.tryParse(dueDate);
    }
    firstPaymentDate ??= now.add(Duration(days: paymentIntervalDays));

    if (annualInterestRate != null && annualInterestRate > 0) {
      // Debt with interest - generate full payment schedule
      paymentSchedule = PaymentSchedule.generate(
        principal: amount,
        annualInterestRate: annualInterestRate,
        currency: currency,
        numberOfInstallments: numberOfInstallments,
        startDate: firstPaymentDate,
        paymentIntervalDays: paymentIntervalDays,
      );
    } else if (numberOfInstallments > 1) {
      // Multiple installments without interest
      paymentSchedule = PaymentSchedule.noInterest(
        principal: amount,
        currency: currency,
        numberOfInstallments: numberOfInstallments,
        startDate: firstPaymentDate,
        paymentIntervalDays: paymentIntervalDays,
      );
    } else if (dueDate != null) {
      // Single payment with due date
      paymentSchedule = PaymentSchedule.singlePayment(
        principal: amount,
        currency: currency,
        dueDate: firstPaymentDate,
        annualInterestRate: annualInterestRate ?? 0,
      );
    }

    // Build content with legal terms and payment schedule
    final entryContent = includeTerms
        ? DefaultTerms.buildCreateContent(
            description: content ?? 'Debt agreement for $description.',
            additionalTerms: additionalTerms,
            governingJurisdiction: governingJurisdiction,
            paymentSchedule: paymentSchedule,
          )
        : content ?? '';

    // Determine the final due date from payment schedule
    final finalDueDate = paymentSchedule?.finalDueDate.toString().substring(0, 10) ?? dueDate;

    // Create the create entry
    final entry = DebtEntry.now(
      author: creditor,
      content: entryContent,
      type: DebtEntryType.create,
      metadata: {
        'status': 'pending',
        'creditor': creditor,
        'creditor_npub': creditorNpub,
        if (creditorName != null) 'creditor_name': creditorName,
        'debtor': debtor,
        'debtor_npub': debtorNpub,
        if (debtorName != null) 'debtor_name': debtorName,
        'amount': amount.toString(),
        'currency': currency,
        if (finalDueDate != null) 'due_date': finalDueDate,
        if (terms != null) 'terms': terms,
        if (annualInterestRate != null && annualInterestRate > 0)
          'interest_rate': annualInterestRate.toString(),
        if (numberOfInstallments > 1)
          'installments': numberOfInstallments.toString(),
        if (paymentSchedule != null)
          'total_with_interest': paymentSchedule.totalAmount.toString(),
      },
    );

    // Sign the entry - required for debt creation
    if (profile != null) {
      final signed = await _signEntry(ledger, entry, profile);
      if (!signed) {
        LogService().log('WalletService: Failed to sign debt creation entry');
        throw Exception('Failed to sign debt. Please ensure your profile has a private key (nsec) configured.');
      }
    } else {
      throw Exception('Profile required to create and sign debt.');
    }

    ledger.addEntry(entry);

    // Save the ledger
    final success = await _saveLedger(ledger);
    if (success) {
      _notifyChange(WalletChangeType.debtCreated, debtId: debtId);
      return ledger;
    }

    return null;
  }

  /// Add an entry to a debt ledger
  Future<bool> addEntry({
    required String debtId,
    required DebtEntryType type,
    required String author,
    String content = '',
    Map<String, String>? metadata,
    Profile? profile,
    String? folderPath,
  }) async {
    final ledger = await findDebt(debtId);
    if (ledger == null) return false;

    final entry = DebtEntry.now(
      author: author,
      content: content,
      type: type,
      metadata: metadata,
    );

    // Sign the entry if profile provided
    if (profile != null) {
      await _signEntry(ledger, entry, profile);
    }

    ledger.addEntry(entry);

    final success = await _saveLedger(ledger);
    if (success) {
      _notifyChange(WalletChangeType.debtUpdated, debtId: debtId);
    }
    return success;
  }

  /// Add a confirm entry (counterparty accepts debt)
  Future<bool> confirmDebt({
    required String debtId,
    required String author,
    String content = '',
    required Profile profile,
  }) async {
    return addEntry(
      debtId: debtId,
      type: DebtEntryType.confirm,
      author: author,
      content: content,
      metadata: {'status': 'open'},
      profile: profile,
    );
  }

  /// Add a reject entry (counterparty declines debt)
  Future<bool> rejectDebt({
    required String debtId,
    required String author,
    String content = '',
    required Profile profile,
  }) async {
    return addEntry(
      debtId: debtId,
      type: DebtEntryType.reject,
      author: author,
      content: content,
      metadata: {'status': 'rejected'},
      profile: profile,
    );
  }

  /// Add a payment entry
  Future<bool> recordPayment({
    required String debtId,
    required String author,
    required double amount,
    required double newBalance,
    String? method,
    String content = '',
    String? file,
    String? sha1,
    required Profile profile,
  }) async {
    final ledger = await findDebt(debtId);
    if (ledger == null) return false;

    final metadata = <String, String>{
      'amount': amount.toString(),
      'currency': ledger.currency ?? 'EUR',
      'balance': newBalance.toString(),
      if (method != null) 'method': method,
      if (file != null) 'file': file,
      if (sha1 != null) 'sha1': sha1,
    };

    return addEntry(
      debtId: debtId,
      type: DebtEntryType.payment,
      author: author,
      content: content,
      metadata: metadata,
      profile: profile,
    );
  }

  /// Add a confirm payment entry
  Future<bool> confirmPayment({
    required String debtId,
    required String author,
    String content = '',
    required Profile profile,
  }) async {
    return addEntry(
      debtId: debtId,
      type: DebtEntryType.confirmPayment,
      author: author,
      content: content,
      profile: profile,
    );
  }

  /// Add a work session entry (for time-based debts)
  Future<bool> recordWorkSession({
    required String debtId,
    required String author,
    required int durationMinutes,
    String? description,
    String? location,
    String content = '',
    required Profile profile,
  }) async {
    final metadata = <String, String>{
      'duration': durationMinutes.toString(),
      if (description != null) 'description': description,
      if (location != null) 'location': location,
    };

    return addEntry(
      debtId: debtId,
      type: DebtEntryType.workSession,
      author: author,
      content: content,
      metadata: metadata,
      profile: profile,
    );
  }

  /// Add a confirm session entry
  Future<bool> confirmWorkSession({
    required String debtId,
    required String author,
    required int newBalanceMinutes,
    String content = '',
    required Profile profile,
  }) async {
    return addEntry(
      debtId: debtId,
      type: DebtEntryType.confirmSession,
      author: author,
      content: content,
      metadata: {'balance': newBalanceMinutes.toString()},
      profile: profile,
    );
  }

  /// Add a status change entry
  Future<bool> changeStatus({
    required String debtId,
    required String author,
    required DebtStatus newStatus,
    String content = '',
    required Profile profile,
  }) async {
    return addEntry(
      debtId: debtId,
      type: DebtEntryType.statusChange,
      author: author,
      content: content,
      metadata: {'status': DebtEntry.statusToString(newStatus)},
      profile: profile,
    );
  }

  /// Add a note entry
  Future<bool> addNote({
    required String debtId,
    required String author,
    required String content,
    required Profile profile,
  }) async {
    return addEntry(
      debtId: debtId,
      type: DebtEntryType.note,
      author: author,
      content: content,
      profile: profile,
    );
  }

  /// Add a witness entry
  Future<bool> addWitness({
    required String debtId,
    required String author,
    String content = '',
    required Profile profile,
  }) async {
    return addEntry(
      debtId: debtId,
      type: DebtEntryType.witness,
      author: author,
      content: content,
      profile: profile,
    );
  }

  // ============ Party Unavailability ============

  /// Declare a debt as uncollectable (by creditor).
  ///
  /// Used when the debtor is unreachable, deceased, or otherwise
  /// unable to fulfill the obligation. Only the creditor can
  /// declare a debt as uncollectable.
  ///
  /// [reason] should be one of: 'disappeared', 'deceased', 'other'
  Future<bool> declareUncollectable({
    required String debtId,
    required String reason,
    required String content,
    required Profile profile,
  }) async {
    final ledger = await findDebt(debtId);
    if (ledger == null) return false;

    // Verify caller is the creditor
    if (ledger.creditorNpub != profile.npub) {
      LogService().log('WalletService: Only creditor can declare debt as uncollectable');
      return false;
    }

    return addEntry(
      debtId: debtId,
      type: DebtEntryType.statusChange,
      author: profile.callsign,
      content: content,
      metadata: {
        'status': 'uncollectable',
        'reason': reason,
      },
      profile: profile,
    );
  }

  /// Declare a debt as unpayable (by debtor).
  ///
  /// Used when the creditor is unreachable, deceased, or otherwise
  /// unable to receive payment. Only the debtor can declare
  /// a debt as unpayable.
  ///
  /// [reason] should be one of: 'disappeared', 'deceased', 'other'
  Future<bool> declareUnpayable({
    required String debtId,
    required String reason,
    required String content,
    required Profile profile,
  }) async {
    final ledger = await findDebt(debtId);
    if (ledger == null) return false;

    // Verify caller is the debtor
    if (ledger.debtorNpub != profile.npub) {
      LogService().log('WalletService: Only debtor can declare debt as unpayable');
      return false;
    }

    return addEntry(
      debtId: debtId,
      type: DebtEntryType.statusChange,
      author: profile.callsign,
      content: content,
      metadata: {
        'status': 'unpayable',
        'reason': reason,
      },
      profile: profile,
    );
  }

  // ============ Debt Transfer ============

  /// Transfer part of a debt to another creditor.
  ///
  /// This is used when:
  /// - Person A owes you (creditor) some amount
  /// - You owe Person C some amount
  /// - You transfer part of A's debt to C
  /// - Result: A now owes C directly, and your debt to C is reduced/settled
  ///
  /// Returns the new debt ID if successful, null otherwise.
  ///
  /// Example:
  /// - Debt 1: A owes B 50 EUR
  /// - Debt 2: B owes C 10 EUR
  /// - B calls transferDebt(sourceDebtId: debt1, amount: 10, newCreditor: C)
  /// - Result:
  ///   - Debt 1: A owes B 40 EUR (reduced by 10)
  ///   - New Debt 3: A owes C 10 EUR (created)
  ///   - Debt 2 can be marked as paid via transferPayment
  Future<String?> transferDebt({
    required String sourceDebtId,
    required double amount,
    required String newCreditor,
    required String newCreditorNpub,
    String? newCreditorName,
    String content = '',
    required Profile profile,
    String? settlementDebtId,
  }) async {
    // 1. Get the source debt
    final sourceLedger = await findDebt(sourceDebtId);
    if (sourceLedger == null) return null;

    // Verify caller is the creditor
    if (sourceLedger.creditorNpub != profile.npub) {
      LogService().log('WalletService: Only creditor can transfer debt');
      return null;
    }

    // Verify sufficient balance
    if (sourceLedger.currentBalance < amount) {
      LogService().log('WalletService: Insufficient balance for transfer');
      return null;
    }

    // 2. Generate new debt ID
    final now = DateTime.now();
    final dateStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final randomId = _generateRandomId(6);
    final newDebtId = 'debt_${dateStr}_$randomId';

    // 3. Create the new debt (A owes C)
    final newLedger = DebtLedger(
      id: newDebtId,
      description: 'Transfer from ${sourceLedger.description}',
      filePath: _buildDebtPath(newDebtId),
    );

    // Create entry with transfer_receive type
    final transferReceiveEntry = DebtEntry.now(
      author: profile.callsign,
      content: content.isEmpty
          ? 'Debt transferred from ${sourceLedger.creditor}'
          : content,
      type: DebtEntryType.transferReceive,
      metadata: {
        'status': 'pending',
        'creditor': newCreditor,
        'creditor_npub': newCreditorNpub,
        if (newCreditorName != null) 'creditor_name': newCreditorName,
        'debtor': sourceLedger.debtor ?? '',
        'debtor_npub': sourceLedger.debtorNpub ?? '',
        if (sourceLedger.debtorName != null)
          'debtor_name': sourceLedger.debtorName!,
        'amount': amount.toString(),
        'currency': sourceLedger.currency ?? 'EUR',
        'source_debt_id': sourceDebtId,
        'original_creditor': sourceLedger.creditor ?? '',
        'original_creditor_npub': sourceLedger.creditorNpub ?? '',
      },
    );

    // Sign the transfer receive entry
    await _signEntry(newLedger, transferReceiveEntry, profile);
    newLedger.addEntry(transferReceiveEntry);

    // Save the new debt
    if (!await _saveLedger(newLedger)) {
      return null;
    }

    // 4. Add transfer entry to source debt
    final newBalance = sourceLedger.currentBalance - amount;
    final transferEntry = DebtEntry.now(
      author: profile.callsign,
      content: content.isEmpty
          ? 'Transferred $amount ${sourceLedger.currency} to $newCreditor'
          : content,
      type: DebtEntryType.transfer,
      metadata: {
        'amount': amount.toString(),
        'currency': sourceLedger.currency ?? 'EUR',
        'balance': newBalance.toString(),
        'new_creditor': newCreditor,
        'new_creditor_npub': newCreditorNpub,
        if (newCreditorName != null) 'new_creditor_name': newCreditorName,
        'target_debt_id': newDebtId,
      },
    );

    await _signEntry(sourceLedger, transferEntry, profile);
    sourceLedger.addEntry(transferEntry);

    if (!await _saveLedger(sourceLedger)) {
      // Rollback: delete the new debt
      await deleteDebt(newDebtId);
      return null;
    }

    // 5. If there's a settlement debt (B owes C), mark it as paid
    if (settlementDebtId != null) {
      await recordTransferPayment(
        debtId: settlementDebtId,
        amount: amount,
        transferDebtId: newDebtId,
        profile: profile,
      );
    }

    _notifyChange(WalletChangeType.debtCreated, debtId: newDebtId);
    _notifyChange(WalletChangeType.debtUpdated, debtId: sourceDebtId);

    return newDebtId;
  }

  /// Record that a debt was paid via a transfer.
  ///
  /// This is used when you receive a transferred debt instead of cash payment.
  Future<bool> recordTransferPayment({
    required String debtId,
    required double amount,
    required String transferDebtId,
    String content = '',
    required Profile profile,
  }) async {
    final ledger = await findDebt(debtId);
    if (ledger == null) return false;

    final newBalance = ledger.currentBalance - amount;
    final status = newBalance <= 0 ? 'paid' : null;

    final metadata = <String, String>{
      'amount': amount.toString(),
      'currency': ledger.currency ?? 'EUR',
      'balance': newBalance.toString(),
      'transfer_debt_id': transferDebtId,
      'method': 'debt_transfer',
      if (status != null) 'status': status,
    };

    return addEntry(
      debtId: debtId,
      type: DebtEntryType.transferPayment,
      author: profile.callsign,
      content: content.isEmpty
          ? 'Paid via debt transfer ($transferDebtId)'
          : content,
      metadata: metadata,
      profile: profile,
    );
  }

  /// Confirm receiving a transferred debt (new creditor accepts).
  Future<bool> confirmTransfer({
    required String debtId,
    required String author,
    String content = '',
    required Profile profile,
  }) async {
    return addEntry(
      debtId: debtId,
      type: DebtEntryType.confirm,
      author: author,
      content: content.isEmpty ? 'I accept this transferred debt.' : content,
      metadata: {'status': 'open'},
      profile: profile,
    );
  }

  /// Move a debt to a different folder
  Future<bool> moveDebt(String debtId, String? targetFolder) async {
    if (_basePath == null) return false;

    final ledger = await findDebt(debtId);
    if (ledger == null || ledger.filePath == null) return false;

    final oldPath = ledger.filePath!;
    final newPath = _buildDebtPath(debtId, folderPath: targetFolder);

    try {
      final oldFile = File(oldPath);
      final newFile = File(newPath);

      // Ensure target directory exists
      await newFile.parent.create(recursive: true);

      // Move file
      await oldFile.rename(newPath);

      _notifyChange(WalletChangeType.debtMoved, debtId: debtId);
      return true;
    } catch (e) {
      LogService().log('WalletService: Error moving debt: $e');
      return false;
    }
  }

  /// Delete a debt
  Future<bool> deleteDebt(String debtId) async {
    final ledger = await findDebt(debtId);
    if (ledger == null || ledger.filePath == null) return false;

    try {
      final file = File(ledger.filePath!);
      if (await file.exists()) {
        await file.delete();
      }
      _notifyChange(WalletChangeType.debtDeleted, debtId: debtId);
      return true;
    } catch (e) {
      LogService().log('WalletService: Error deleting debt: $e');
      return false;
    }
  }

  /// Delete an entry from a debt ledger by index.
  Future<bool> deleteEntry({
    required String debtId,
    required int entryIndex,
  }) async {
    final ledger = await findDebt(debtId);
    if (ledger == null) return false;

    if (entryIndex < 0 || entryIndex >= ledger.entries.length) {
      return false;
    }

    // Remove the entry
    ledger.entries.removeAt(entryIndex);

    // Save the updated ledger
    final success = await _saveLedger(ledger);
    if (success) {
      _notifyChange(WalletChangeType.debtUpdated, debtId: debtId);
    }
    return success;
  }

  // ============ Verification ============

  /// Verify all signatures in a debt ledger
  Future<bool> verifyDebt(DebtLedger ledger) async {
    if (ledger.entries.isEmpty) return true;

    // Build content progressively and verify each entry
    final buffer = StringBuffer();
    buffer.writeln('# ${ledger.id}: ${ledger.description}');

    for (int i = 0; i < ledger.entries.length; i++) {
      final entry = ledger.entries[i];

      if (!entry.isSigned) {
        // Unsigned entries are valid but not verified
        continue;
      }

      // Content up to this entry (excluding signature)
      final contentToVerify = _buildContentToVerify(ledger, i);

      // Verify using NOSTR event structure
      final verified = _verifyEntrySignature(entry, contentToVerify, ledger.id);
      entry.verified = verified;

      if (!verified) {
        // Once an entry is invalid, all entries below are also invalid
        for (int j = i + 1; j < ledger.entries.length; j++) {
          ledger.entries[j].verified = false;
        }
        return false;
      }
    }

    return true;
  }

  /// Verify a single entry's signature
  bool _verifyEntrySignature(DebtEntry entry, String contentToVerify, String debtId) {
    try {
      final npub = entry.npub;
      final signature = entry.signature;

      if (npub == null || signature == null) {
        return false;
      }

      // Get hex pubkey from npub
      final pubkeyHex = NostrCrypto.decodeNpub(npub);

      // Get created_at from entry metadata
      final createdAtStr = entry.getMeta('created_at');
      final createdAt = createdAtStr != null
          ? int.parse(createdAtStr)
          : entry.dateTime.millisecondsSinceEpoch ~/ 1000;

      // Reconstruct NOSTR event per wallet-format-specification.md
      final event = NostrEvent(
        pubkey: pubkeyHex,
        createdAt: createdAt,
        kind: 1,
        tags: [
          ['t', 'wallet'],
          ['debt_id', debtId],
          ['callsign', entry.author],
        ],
        content: contentToVerify,
        sig: signature,
      );

      event.calculateId();
      return event.verify();
    } catch (e) {
      LogService().log('WalletService: Error verifying signature: $e');
      return false;
    }
  }

  // ============ Summary ============

  /// Get wallet summary (total owed/owing)
  Future<WalletSummary> getSummary(String userNpub) async {
    final debts = await listAllDebts();
    return WalletSummary.fromDebts(debts, userNpub);
  }

  // ============ Receipt Operations ============

  /// List all receipts in a folder (or root if folderPath is null)
  Future<List<Receipt>> listReceipts({String? folderPath}) async {
    if (_basePath == null) return [];

    try {
      final searchPath = folderPath != null
          ? path.join(_basePath!, 'receipts', folderPath)
          : path.join(_basePath!, 'receipts');

      final dir = Directory(searchPath);
      if (!await dir.exists()) return [];

      final receipts = <Receipt>[];
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.md')) {
          try {
            final content = await entity.readAsString();
            final receipt = Receipt.parseFromMarkdown(content);
            if (receipt != null) {
              receipts.add(receipt);
            }
          } catch (e) {
            LogService().log('WalletService: Error reading receipt ${entity.path}: $e');
          }
        }
      }

      // Sort by timestamp, newest first
      receipts.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return receipts;
    } catch (e) {
      LogService().log('WalletService: Error listing receipts: $e');
      return [];
    }
  }

  /// List all receipts recursively
  Future<List<Receipt>> listAllReceipts() async {
    if (_basePath == null) return [];

    final allReceipts = <Receipt>[];

    // Get receipts at root level
    allReceipts.addAll(await listReceipts());

    // Get receipts in each folder
    final receiptsDir = Directory(path.join(_basePath!, 'receipts'));
    if (await receiptsDir.exists()) {
      await for (final entity in receiptsDir.list()) {
        if (entity is Directory) {
          final folderName = path.basename(entity.path);
          if (!folderName.startsWith('.') && folderName != 'media') {
            allReceipts.addAll(await listReceipts(folderPath: folderName));
          }
        }
      }
    }

    return allReceipts;
  }

  /// Get a receipt by ID
  Future<Receipt?> getReceipt(String receiptId, {String? folderPath}) async {
    if (_basePath == null) return null;

    final filePath = _buildReceiptPath(receiptId, folderPath: folderPath);
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      return Receipt.parseFromMarkdown(content);
    } catch (e) {
      LogService().log('WalletService: Error reading receipt: $e');
      return null;
    }
  }

  /// Find a receipt by ID (searches all folders)
  Future<Receipt?> findReceipt(String receiptId) async {
    if (_basePath == null) return null;

    // Try root first
    var receipt = await getReceipt(receiptId);
    if (receipt != null) return receipt;

    // Search folders
    final receiptsDir = Directory(path.join(_basePath!, 'receipts'));
    if (await receiptsDir.exists()) {
      await for (final entity in receiptsDir.list()) {
        if (entity is Directory) {
          final folderName = path.basename(entity.path);
          if (!folderName.startsWith('.') && folderName != 'media') {
            receipt = await getReceipt(receiptId, folderPath: folderName);
            if (receipt != null) return receipt;
          }
        }
      }
    }

    return null;
  }

  /// Create a new payment receipt.
  ///
  /// Creates a cryptographically signed record of a completed payment.
  /// The receipt includes timestamp, location, and can be signed by
  /// both parties and witnesses.
  ///
  /// [description] - What the payment was for
  /// [payer] - Who made the payment (callsign)
  /// [payerNpub] - Payer's NOSTR public key
  /// [payee] - Who received the payment (callsign)
  /// [payeeNpub] - Payee's NOSTR public key
  /// [amount] - Amount paid
  /// [currency] - Currency code
  /// [paymentMethod] - How the payment was made (cash, transfer, etc.)
  /// [location] - GPS coordinates where payment occurred
  /// [profile] - Profile to sign the receipt with (usually the payer)
  Future<Receipt?> createReceipt({
    required String description,
    required String payer,
    required String payerNpub,
    String? payerName,
    required String payee,
    required String payeeNpub,
    String? payeeName,
    required double amount,
    required String currency,
    String? notes,
    String? paymentMethod,
    String? reference,
    ReceiptLocation? location,
    List<String>? tags,
    String? folderPath,
    required Profile profile,
  }) async {
    if (_basePath == null) return null;

    // Generate receipt ID
    final receiptId = Receipt.generateId();
    final now = DateTime.now();

    // Create receipt parties
    final payerParty = ReceiptParty(
      callsign: payer,
      npub: payerNpub,
      name: payerName,
    );
    final payeeParty = ReceiptParty(
      callsign: payee,
      npub: payeeNpub,
      name: payeeName,
    );

    // Create unsigned receipt
    var receipt = Receipt(
      id: receiptId,
      timestamp: now,
      payer: payerParty,
      payee: payeeParty,
      amount: amount,
      currency: currency,
      description: description,
      notes: notes,
      location: location,
      paymentMethod: paymentMethod,
      reference: reference,
      tags: tags ?? [],
      status: ReceiptStatus.draft,
    );

    // Sign as payer if the profile matches
    if (profile.npub == payerNpub) {
      receipt = await _signReceiptAsPayer(receipt, profile);
    }

    // Save the receipt
    final success = await _saveReceipt(receipt, folderPath: folderPath);
    if (success) {
      _notifyChange(WalletChangeType.receiptCreated, receiptId: receiptId);
      return receipt;
    }

    return null;
  }

  /// Sign a receipt as the payer.
  Future<Receipt?> signReceiptAsPayer({
    required String receiptId,
    required Profile profile,
  }) async {
    var receipt = await findReceipt(receiptId);
    if (receipt == null) return null;

    // Verify caller is the payer
    if (receipt.payer.npub != profile.npub) {
      LogService().log('WalletService: Only payer can sign as payer');
      return null;
    }

    receipt = await _signReceiptAsPayer(receipt, profile);
    await _saveReceipt(receipt);
    _notifyChange(WalletChangeType.receiptUpdated, receiptId: receiptId);
    return receipt;
  }

  /// Sign a receipt as the payee (confirm receipt of payment).
  Future<Receipt?> signReceiptAsPayee({
    required String receiptId,
    required Profile profile,
  }) async {
    var receipt = await findReceipt(receiptId);
    if (receipt == null) return null;

    // Verify caller is the payee
    if (receipt.payee.npub != profile.npub) {
      LogService().log('WalletService: Only payee can sign as payee');
      return null;
    }

    receipt = await _signReceiptAsPayee(receipt, profile);
    await _saveReceipt(receipt);
    _notifyChange(WalletChangeType.receiptUpdated, receiptId: receiptId);
    return receipt;
  }

  /// Add a witness signature to a receipt.
  Future<Receipt?> addReceiptWitness({
    required String receiptId,
    required Profile profile,
  }) async {
    var receipt = await findReceipt(receiptId);
    if (receipt == null) return null;

    receipt = await _signReceiptAsWitness(receipt, profile);
    await _saveReceipt(receipt);
    _notifyChange(WalletChangeType.receiptUpdated, receiptId: receiptId);
    return receipt;
  }

  /// Add an attachment to a receipt.
  Future<Receipt?> addReceiptAttachment({
    required String receiptId,
    required String filename,
    required String sha1,
    String? mimeType,
  }) async {
    var receipt = await findReceipt(receiptId);
    if (receipt == null) return null;

    final attachment = ReceiptAttachment(
      filename: filename,
      sha1: sha1,
      mimeType: mimeType,
    );

    receipt = receipt.copyWith(
      attachments: [...receipt.attachments, attachment],
    );

    await _saveReceipt(receipt);
    _notifyChange(WalletChangeType.receiptUpdated, receiptId: receiptId);
    return receipt;
  }

  /// Move a receipt to a different folder
  Future<bool> moveReceipt(String receiptId, String? targetFolder) async {
    if (_basePath == null) return false;

    final receipt = await findReceipt(receiptId);
    if (receipt == null) return false;

    // Find current file path
    final currentPath = await _findReceiptPath(receiptId);
    if (currentPath == null) return false;

    final newPath = _buildReceiptPath(receiptId, folderPath: targetFolder);

    try {
      final oldFile = File(currentPath);
      final newFile = File(newPath);

      // Ensure target directory exists
      await newFile.parent.create(recursive: true);

      // Move file
      await oldFile.rename(newPath);

      _notifyChange(WalletChangeType.receiptMoved, receiptId: receiptId);
      return true;
    } catch (e) {
      LogService().log('WalletService: Error moving receipt: $e');
      return false;
    }
  }

  /// Delete a receipt
  Future<bool> deleteReceipt(String receiptId) async {
    final filePath = await _findReceiptPath(receiptId);
    if (filePath == null) return false;

    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
      _notifyChange(WalletChangeType.receiptDeleted, receiptId: receiptId);
      return true;
    } catch (e) {
      LogService().log('WalletService: Error deleting receipt: $e');
      return false;
    }
  }

  /// Verify all signatures on a receipt.
  Future<bool> verifyReceipt(Receipt receipt) async {
    try {
      // Verify payer signature
      if (receipt.payerSignature != null) {
        final payerValid = _verifyReceiptSignature(
          receipt,
          receipt.payerSignature!,
          'receipt',
        );
        if (!payerValid) return false;
      }

      // Verify payee signature
      if (receipt.payeeSignature != null) {
        final payeeValid = _verifyReceiptSignature(
          receipt,
          receipt.payeeSignature!,
          'confirm_receipt',
        );
        if (!payeeValid) return false;
      }

      // Verify witness signatures
      for (final witness in receipt.witnessSignatures) {
        final witnessValid = _verifyReceiptSignature(
          receipt,
          witness,
          'witness',
        );
        if (!witnessValid) return false;
      }

      return true;
    } catch (e) {
      LogService().log('WalletService: Error verifying receipt: $e');
      return false;
    }
  }

  // ============ Receipt Internal Methods ============

  String _buildReceiptPath(String receiptId, {String? folderPath}) {
    if (folderPath != null) {
      return path.join(_basePath!, 'receipts', folderPath, '$receiptId.md');
    }
    return path.join(_basePath!, 'receipts', '$receiptId.md');
  }

  Future<String?> _findReceiptPath(String receiptId) async {
    if (_basePath == null) return null;

    // Try root first
    var filePath = _buildReceiptPath(receiptId);
    if (await File(filePath).exists()) return filePath;

    // Search folders
    final receiptsDir = Directory(path.join(_basePath!, 'receipts'));
    if (await receiptsDir.exists()) {
      await for (final entity in receiptsDir.list()) {
        if (entity is Directory) {
          final folderName = path.basename(entity.path);
          if (!folderName.startsWith('.') && folderName != 'media') {
            filePath = _buildReceiptPath(receiptId, folderPath: folderName);
            if (await File(filePath).exists()) return filePath;
          }
        }
      }
    }

    return null;
  }

  Future<bool> _saveReceipt(Receipt receipt, {String? folderPath}) async {
    if (_basePath == null) return false;

    // Find existing path or create new one
    var filePath = await _findReceiptPath(receipt.id);
    filePath ??= _buildReceiptPath(receipt.id, folderPath: folderPath);

    try {
      final file = File(filePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(receipt.toMarkdown());
      return true;
    } catch (e) {
      LogService().log('WalletService: Error saving receipt: $e');
      return false;
    }
  }

  Future<Receipt> _signReceiptAsPayer(Receipt receipt, Profile profile) async {
    final contentToSign = _buildReceiptContentToSign(receipt, 'receipt');
    final signature = await _signContent(contentToSign, receipt.id, profile);

    if (signature != null) {
      return receipt.copyWith(
        payerSignature: ReceiptSignature(
          npub: profile.npub,
          signature: signature,
          timestamp: DateTime.now(),
          callsign: profile.callsign,
        ),
        status: ReceiptStatus.issued,
      );
    }
    return receipt;
  }

  Future<Receipt> _signReceiptAsPayee(Receipt receipt, Profile profile) async {
    final contentToSign = _buildReceiptContentToSign(receipt, 'confirm_receipt');
    final signature = await _signContent(contentToSign, receipt.id, profile);

    if (signature != null) {
      return receipt.copyWith(
        payeeSignature: ReceiptSignature(
          npub: profile.npub,
          signature: signature,
          timestamp: DateTime.now(),
          callsign: profile.callsign,
        ),
        status: ReceiptStatus.confirmed,
      );
    }
    return receipt;
  }

  Future<Receipt> _signReceiptAsWitness(Receipt receipt, Profile profile) async {
    final contentToSign = _buildReceiptContentToSign(receipt, 'witness');
    final signature = await _signContent(contentToSign, receipt.id, profile);

    if (signature != null) {
      final witnessSignature = ReceiptSignature(
        npub: profile.npub,
        signature: signature,
        timestamp: DateTime.now(),
        callsign: profile.callsign,
      );
      return receipt.copyWith(
        witnessSignatures: [...receipt.witnessSignatures, witnessSignature],
      );
    }
    return receipt;
  }

  Future<String?> _signContent(String content, String documentId, Profile profile) async {
    try {
      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      final event = NostrEvent.textNote(
        pubkeyHex: pubkeyHex,
        content: content,
        tags: [
          ['t', 'wallet'],
          ['receipt_id', documentId],
          ['callsign', profile.callsign],
        ],
        createdAt: createdAt,
      );

      final signedEvent = await SigningService().signEvent(event, profile);
      return signedEvent?.sig;
    } catch (e) {
      LogService().log('WalletService: Error signing content: $e');
      return null;
    }
  }

  String _buildReceiptContentToSign(Receipt receipt, String entryType) {
    final buffer = StringBuffer();

    // Header
    buffer.writeln('# ${receipt.id}: ${receipt.description}');
    buffer.writeln();

    // Main receipt data
    buffer.writeln('> ${ChatFormat.formatTimestamp(receipt.timestamp)} -- ${receipt.payer.callsign}');
    buffer.writeln('--> type: $entryType');
    buffer.writeln('--> payer: ${receipt.payer.callsign}');
    buffer.writeln('--> payer_npub: ${receipt.payer.npub}');
    if (receipt.payer.name != null) {
      buffer.writeln('--> payer_name: ${receipt.payer.name}');
    }
    buffer.writeln('--> payee: ${receipt.payee.callsign}');
    buffer.writeln('--> payee_npub: ${receipt.payee.npub}');
    if (receipt.payee.name != null) {
      buffer.writeln('--> payee_name: ${receipt.payee.name}');
    }
    buffer.writeln('--> amount: ${receipt.amount}');
    buffer.writeln('--> currency: ${receipt.currency}');

    if (receipt.paymentMethod != null) {
      buffer.writeln('--> method: ${receipt.paymentMethod}');
    }
    if (receipt.reference != null) {
      buffer.writeln('--> reference: ${receipt.reference}');
    }
    if (receipt.location != null) {
      buffer.writeln('--> lat: ${receipt.location!.latitude}');
      buffer.writeln('--> lon: ${receipt.location!.longitude}');
      if (receipt.location!.accuracy != null) {
        buffer.writeln('--> accuracy: ${receipt.location!.accuracy}');
      }
      if (receipt.location!.placeName != null) {
        buffer.writeln('--> place: ${receipt.location!.placeName}');
      }
    }
    if (receipt.tags.isNotEmpty) {
      buffer.writeln('--> tags: ${receipt.tags.join(', ')}');
    }

    for (final attachment in receipt.attachments) {
      buffer.writeln('--> file: ${attachment.filename}');
      buffer.writeln('--> sha1: ${attachment.sha1}');
    }

    buffer.writeln(receipt.description);
    if (receipt.notes != null && receipt.notes!.isNotEmpty) {
      buffer.writeln();
      buffer.writeln(receipt.notes);
    }

    return buffer.toString().trimRight();
  }

  bool _verifyReceiptSignature(
    Receipt receipt,
    ReceiptSignature signature,
    String entryType,
  ) {
    try {
      final pubkeyHex = NostrCrypto.decodeNpub(signature.npub);
      final contentToVerify = _buildReceiptContentToSign(receipt, entryType);
      final createdAt = signature.timestamp.millisecondsSinceEpoch ~/ 1000;

      final event = NostrEvent(
        pubkey: pubkeyHex,
        createdAt: createdAt,
        kind: 1,
        tags: [
          ['t', 'wallet'],
          ['receipt_id', receipt.id],
          ['callsign', signature.callsign ?? ''],
        ],
        content: contentToVerify,
        sig: signature.signature,
      );

      event.calculateId();
      return event.verify();
    } catch (e) {
      LogService().log('WalletService: Error verifying receipt signature: $e');
      return false;
    }
  }

  // ============ Internal Methods ============

  String _buildDebtPath(String debtId, {String? folderPath}) {
    if (folderPath != null) {
      return path.join(_basePath!, 'debts', folderPath, '$debtId.md');
    }
    return path.join(_basePath!, 'debts', '$debtId.md');
  }

  Future<DebtLedger?> _readLedgerFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      return DebtLedger.parse(content, filePath: filePath);
    } catch (e) {
      LogService().log('WalletService: Error reading ledger: $e');
      return null;
    }
  }

  Future<bool> _saveLedger(DebtLedger ledger) async {
    if (ledger.filePath == null) return false;

    try {
      final file = File(ledger.filePath!);
      await file.parent.create(recursive: true);
      await file.writeAsString(ledger.export());
      return true;
    } catch (e) {
      LogService().log('WalletService: Error saving ledger: $e');
      return false;
    }
  }

  /// Sign an entry with the user's profile.
  /// Returns true if signing was successful, false otherwise.
  Future<bool> _signEntry(DebtLedger ledger, DebtEntry entry, Profile profile) async {
    try {
      // Check if profile has signing capability
      if (profile.nsec.isEmpty) {
        LogService().log('WalletService: Cannot sign - no nsec key in profile');
        return false;
      }

      // Get content to sign (everything above signature)
      final contentToSign = ledger.getContentToSign(entry);

      // Get pubkey hex
      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);

      // Get current unix timestamp
      final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // Create NOSTR event for signing
      final event = NostrEvent.textNote(
        pubkeyHex: pubkeyHex,
        content: contentToSign,
        tags: [
          ['t', 'wallet'],
          ['debt_id', ledger.id],
          ['callsign', entry.author],
        ],
        createdAt: createdAt,
      );

      // Sign using SigningService
      final signedEvent = await SigningService().signEvent(event, profile);
      if (signedEvent != null && signedEvent.sig != null) {
        entry.setMeta('created_at', createdAt.toString());
        entry.setMeta('npub', profile.npub);
        entry.setMeta('signature', signedEvent.sig!);
        entry.verified = true;
        return true;
      } else {
        LogService().log('WalletService: Signing failed - no signature returned');
        return false;
      }
    } catch (e) {
      LogService().log('WalletService: Error signing entry: $e');
      return false;
    }
  }

  String _buildContentToVerify(DebtLedger ledger, int entryIndex) {
    final buffer = StringBuffer();

    // Header
    buffer.writeln('# ${ledger.id}: ${ledger.description}');

    // All entries up to and including current (without signature line)
    for (int i = 0; i <= entryIndex; i++) {
      final entry = ledger.entries[i];
      buffer.writeln();
      buffer.writeln();
      buffer.writeln('> ${entry.timestamp} -- ${entry.author}');
      buffer.writeln('--> type: ${DebtEntry.typeToString(entry.type)}');

      // Metadata (excluding reserved keys)
      const reservedKeys = {'type', 'npub', 'signature', 'created_at'};
      for (final meta in entry.metadata.entries) {
        if (reservedKeys.contains(meta.key)) continue;
        buffer.writeln('--> ${meta.key}: ${meta.value}');
      }

      // Content
      if (entry.content.isNotEmpty) {
        buffer.writeln(entry.content);
      }

      // created_at (if present)
      if (entry.hasMeta('created_at')) {
        buffer.writeln('--> created_at: ${entry.getMeta('created_at')}');
      }

      // npub (included in signed content for current entry only)
      if (i == entryIndex && entry.hasMeta('npub')) {
        buffer.writeln('--> npub: ${entry.npub}');
      }
    }

    return buffer.toString().trimRight();
  }

  String _generateRandomId(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = DateTime.now().microsecondsSinceEpoch;
    var seed = random;
    final buffer = StringBuffer();
    for (int i = 0; i < length; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
      buffer.write(chars[seed % chars.length]);
    }
    return buffer.toString();
  }

  void _notifyChange(
    WalletChangeType type, {
    String? folderPath,
    String? debtId,
    String? receiptId,
  }) {
    _changesController.add(WalletChange(
      type: type,
      folderPath: folderPath,
      debtId: debtId,
      receiptId: receiptId,
    ));
  }

  void dispose() {
    _changesController.close();
  }
}

/// Types of wallet changes
enum WalletChangeType {
  folderCreated,
  folderDeleted,
  folderRenamed,
  debtCreated,
  debtUpdated,
  debtMoved,
  debtDeleted,
  receiptCreated,
  receiptUpdated,
  receiptMoved,
  receiptDeleted,
  syncReceived,
}

/// Represents a wallet change event
class WalletChange {
  final WalletChangeType type;
  final String? folderPath;
  final String? debtId;
  final String? receiptId;
  final DateTime timestamp;

  WalletChange({
    required this.type,
    this.folderPath,
    this.debtId,
    this.receiptId,
  }) : timestamp = DateTime.now();
}
