import '../../ai/core/bill_info.dart';
import '../../l10n/app_localizations.dart';
import 'bookkeeping_result.dart';

String billingTypeLabel(AppLocalizations l, BillType? type) => switch (type) {
      BillType.income => l.aiTypeIncome,
      BillType.transfer => l.appLinkTypeTransfer,
      _ => l.aiTypeExpense,
    };

/// Financial outcome is separate from optional attachments and synchronization.
String bookkeepingFeedback(AppLocalizations l, BookkeepingResult result,
    {bool postProcessingFailed = false, bool includeCounts = true}) {
  final lines = <String>[];
  if (includeCounts && result.createdCount > 0) {
    lines.add(l.aiBillingSavedCount(result.createdCount));
  }
  if (includeCounts && result.reusedTransactionIds.isNotEmpty) {
    lines.add(l.aiBillingAlreadySavedCount(result.reusedTransactionIds.length));
  }
  final amounts = <(BillType?, String), double>{};
  for (final bill in result.createdBills) {
    final key = (bill.type, bill.currency ?? 'CNY');
    amounts.update(key, (amount) => amount + (bill.amount?.abs() ?? 0),
        ifAbsent: () => bill.amount?.abs() ?? 0);
  }
  for (final entry in amounts.entries) {
    lines.add('${billingTypeLabel(l, entry.key.$1)} ${entry.key.$2} '
        '${entry.value.toStringAsFixed(2)}');
  }
  if (result.failedCount > 0) {
    lines.add(l.aiBillingFailedCount(result.failedCount));
  }
  if (result.attachmentFailureCount > 0) {
    lines.add(l.aiBillingAttachmentFailedCount(result.attachmentFailureCount));
  }
  if (postProcessingFailed) lines.add(l.aiBillingPostProcessingPending);
  if (result.unconvertedCurrencies.isNotEmpty) {
    lines.add(
        l.aiBillingRateMissingHint(result.unconvertedCurrencies.join('、')));
  }
  return lines.join('\n');
}
