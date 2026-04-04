/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/accounting_content.dart';
import '../../models/spreadsheet_content.dart';

/// Card widget for displaying a single accounting entry
class AccountingEntryCardWidget extends StatelessWidget {
  final AccountingEntry entry;
  final String currencyCode;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const AccountingEntryCardWidget({
    super.key,
    required this.entry,
    required this.currencyCode,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isIncome = entry.type == AccountingEntryType.income;
    final color = isIncome ? Colors.green : Colors.red;
    final currency = CurrencyFormat.byCode(currencyCode);
    final sign = isIncome ? '+' : '-';

    String formattedAmount;
    if (currency != null) {
      // Cap decimals for display: 2 for fiat, 4 for crypto
      final displayDecimals = currency.isCrypto ? 4 : 2;
      final formatted = entry.amount.toStringAsFixed(displayDecimals);
      if (currency.symbolBefore) {
        formattedAmount = '$sign${currency.symbol}$formatted';
      } else {
        formattedAmount = '$sign$formatted ${currency.symbol}';
      }
    } else {
      formattedAmount = '$sign${entry.amount.toStringAsFixed(2)} $currencyCode';
    }

    final dateStr = DateFormat.yMMMd().format(entry.date);

    return Dismissible(
      key: Key(entry.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: theme.colorScheme.error,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        onDelete();
        return false; // Let the parent handle deletion
      },
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(
            isIncome ? Icons.arrow_upward : Icons.arrow_downward,
            color: color,
            size: 20,
          ),
        ),
        title: Text(
          entry.description,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Row(
          children: [
            Text(dateStr, style: theme.textTheme.bodySmall),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                entry.category,
                style: theme.textTheme.labelSmall,
              ),
            ),
          ],
        ),
        trailing: Text(
          formattedAmount,
          style: theme.textTheme.titleSmall?.copyWith(
            color: color,
            fontWeight: FontWeight.bold,
          ),
        ),
        onTap: onEdit,
      ),
    );
  }
}
