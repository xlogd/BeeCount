import 'package:csv/csv.dart';
import 'package:path/path.dart' as p;

import '../../../../data/db.dart';
import '../../../../data/repositories/base_repository.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../models/transaction_export_column.dart';
import '../../../../models/transaction_export_filter.dart';
import '../../../../utils/category_utils.dart';
import '../../../../utils/invoice_file.dart';

class TransactionExportAttachment {
  const TransactionExportAttachment(this.attachment, this.archivePath);
  final TransactionAttachment attachment;
  final String archivePath;
}

/// Exports a ledger snapshot using the selected column order after the sequence.
Future<String> buildTransactionExportCsv({
  required BaseRepository repo,
  required int ledgerId,
  required AppLocalizations l10n,
  List<TransactionExportColumn>? columns,
  TransactionExportFilter filter = const TransactionExportFilter.all(),
  bool packageAttachments = false,
  void Function(List<TransactionExportAttachment> attachments)? onAttachments,
  void Function(int count)? onRecordCount,
  void Function(double)? onProgress,
}) async {
  // Copy before the first await so an in-flight export cannot change shape.
  final selected = validateTransactionExportColumns(columns);
  final csvColumns = selected
      .where((column) => column != TransactionExportColumn.attachments)
      .toList(growable: false);
  final fields = selected.toSet();
  final snapshot =
      await repo.transactionsWithCategoryAll(ledgerId: ledgerId).first;
  final transactions = snapshot
      .where((row) => filter.matches(
          happenedAt: row.t.happenedAt, transactionType: row.t.type))
      .toList(growable: false);
  onRecordCount?.call(transactions.length);
  const encoder = ListToCsvConverter(eol: '\n');
  final output = StringBuffer(
      encoder.convert([exportCsvHeaders(l10n, columns: selected)]));
  if (transactions.isEmpty) {
    onAttachments?.call(const []);
    onProgress?.call(1);
    return output.toString();
  }

  final ids = transactions.map((row) => row.t.id).toList();
  final tags = <int, List<Tag>>{};
  final attachments = <int, List<TransactionAttachment>>{};
  // Keep queries below SQLite's variable limit, including on older devices.
  if (fields.contains(TransactionExportColumn.tags) ||
      fields.contains(TransactionExportColumn.attachments)) {
    for (var start = 0; start < ids.length; start += 500) {
      final batch = ids.sublist(start, (start + 500).clamp(0, ids.length));
      if (fields.contains(TransactionExportColumn.tags)) {
        tags.addAll(await repo.getTagsForTransactions(batch));
      }
      if (fields.contains(TransactionExportColumn.attachments)) {
        attachments.addAll(await repo.getAttachmentsForTransactions(batch));
      }
    }
  }
  final needsAccounts = fields.any(const {
    TransactionExportColumn.currency,
    TransactionExportColumn.account,
    TransactionExportColumn.fromAccount,
    TransactionExportColumn.toAccount,
  }.contains);
  final accounts = needsAccounts ? await repo.getAllAccounts() : <Account>[];
  final accountMap = {for (final account in accounts) account.id: account};
  var ledgerCurrency = 'CNY';
  if (fields.contains(TransactionExportColumn.currency)) {
    final ledger = await repo.getLedgerById(ledgerId);
    if (ledger != null && ledger.currency.isNotEmpty) {
      ledgerCurrency = ledger.currency.toUpperCase();
    }
  }

  final parents = <int, Category>{};
  if (fields.contains(TransactionExportColumn.category) &&
      transactions.any((row) => row.category?.level == 2)) {
    for (final kind in ['income', 'expense']) {
      for (final category in await repo.getTopLevelCategories(kind)) {
        parents[category.id] = category;
      }
    }
  }

  final exportAttachments = <TransactionExportAttachment>[];
  for (var i = 0; i < transactions.length; i++) {
    final row = transactions[i];
    final transaction = row.t;
    final rowAttachments =
        attachments[transaction.id] ?? <TransactionAttachment>[];
    if (packageAttachments) {
      for (var index = 0; index < rowAttachments.length; index++) {
        exportAttachments.add(TransactionExportAttachment(
            rowAttachments[index],
            transactionExportAttachmentPath(
                l10n: l10n,
                sequence: i + 1,
                attachment: rowAttachments[index],
                imageIndex: index + 1,
                imageCount: rowAttachments.length,
                note: transaction.note)));
      }
    }
    final category = row.category;
    final account = accountMap[transaction.accountId];
    final transfer = transaction.type == 'transfer';
    final child = category?.level == 2 && category?.parentId != null;
    Object value(TransactionExportColumn column) => switch (column) {
          TransactionExportColumn.type =>
            exportTypeDisplayName(l10n, transaction.type),
          TransactionExportColumn.category => transfer || category == null
              ? ''
              : CategoryUtils.displayName(
                  child ? parents[category.parentId]?.name : category.name,
                  l10n),
          TransactionExportColumn.subCategory => !transfer && child
              ? CategoryUtils.displayName(category!.name, l10n)
              : '',
          TransactionExportColumn.amount =>
            transaction.amount.toStringAsFixed(2),
          TransactionExportColumn.currency => (transaction.currencyCode ??
                  (account?.currency.isNotEmpty == true
                      ? account!.currency
                      : null) ??
                  ledgerCurrency)
              .toUpperCase(),
          TransactionExportColumn.account =>
            transfer ? '' : account?.name ?? '',
          TransactionExportColumn.fromAccount =>
            transfer ? account?.name ?? '' : '',
          TransactionExportColumn.toAccount =>
            transfer ? accountMap[transaction.toAccountId]?.name ?? '' : '',
          TransactionExportColumn.note => transaction.note ?? '',
          TransactionExportColumn.time => _exportTime(transaction.happenedAt),
          TransactionExportColumn.tags =>
            (tags[transaction.id] ?? <Tag>[]).map((tag) => tag.name).join(','),
          TransactionExportColumn.attachments => throw StateError(
              'Attachments are a package option, not a CSV column'),
        };
    // Encode rows directly instead of retaining a second copy of the ledger.
    output.write('\n');
    final values = [i + 1, ...csvColumns.map(value)];
    encoder.convertSingleRow(output, values, returnString: false);
    if (i % 50 == 0 || i == transactions.length - 1) {
      onProgress?.call((i + 1) / transactions.length);
    }
  }
  onAttachments?.call(exportAttachments);
  return output.toString();
}

String transactionExportAttachmentPath({
  required AppLocalizations l10n,
  required int sequence,
  required TransactionAttachment attachment,
  required int imageIndex,
  required int imageCount,
  required String? note,
}) {
  final extension = p.extension(attachment.fileName).toLowerCase();
  final safeExtension =
      RegExp(r'^\.[a-z0-9]{1,10}$').hasMatch(extension) ? extension : '.bin';
  final cleanNote =
      (note ?? '').replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
  final shortNote = String.fromCharCodes(cleanNote.runes.take(40));
  final notePart = shortNote.isEmpty ? l10n.exportAttachmentNoNote : shortNote;
  final imagePart = imageCount > 1 ? '-$imageIndex' : '';
  final folder = isInvoiceFile(attachment.fileName) ? '发票' : '附件';
  return '$folder/${l10n.exportCsvHeaderSequence}-$sequence$imagePart-$notePart$safeExtension';
}

String _exportTime(DateTime time) {
  final local = time.toLocal();
  return '  ${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}  ';
}

String exportCsvColumnLabel(
        AppLocalizations l10n, TransactionExportColumn column) =>
    switch (column) {
      TransactionExportColumn.type => l10n.exportCsvHeaderType,
      TransactionExportColumn.category => l10n.exportCsvHeaderCategory,
      TransactionExportColumn.subCategory => l10n.exportCsvHeaderSubCategory,
      TransactionExportColumn.amount => l10n.exportCsvHeaderAmount,
      TransactionExportColumn.currency => l10n.exportCsvHeaderCurrency,
      TransactionExportColumn.account => l10n.exportCsvHeaderAccount,
      TransactionExportColumn.fromAccount => l10n.exportCsvHeaderFromAccount,
      TransactionExportColumn.toAccount => l10n.exportCsvHeaderToAccount,
      TransactionExportColumn.note => l10n.exportCsvHeaderNote,
      TransactionExportColumn.time => l10n.exportCsvHeaderTime,
      TransactionExportColumn.tags => l10n.exportCsvHeaderTags,
      TransactionExportColumn.attachments => l10n.exportCsvHeaderAttachments,
    };

List<String> exportCsvHeaders(AppLocalizations l10n,
        {List<TransactionExportColumn>? columns}) =>
    [
      l10n.exportCsvHeaderSequence,
      ...validateTransactionExportColumns(columns)
          .where((column) => column != TransactionExportColumn.attachments)
          .map((column) => exportCsvColumnLabel(l10n, column))
    ];

String exportTypeDisplayName(AppLocalizations l10n, String type) =>
    switch (type) {
      'income' => l10n.exportTypeIncome,
      'expense' => l10n.exportTypeExpense,
      'transfer' => l10n.exportTypeTransfer,
      _ => type,
    };
