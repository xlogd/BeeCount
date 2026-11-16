import 'package:beecount/ai/core/bill_info.dart';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/services/ai/bookkeeping_feedback.dart';
import 'package:beecount/services/ai/bookkeeping_result.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final locale in [
    const Locale('zh'),
    const Locale('zh', 'TW'),
    const Locale('en'),
    const Locale('ko')
  ]) {
    test(
        'mixed types/currencies and ancillary failures remain explicit: $locale',
        () {
      final l = lookupAppLocalizations(locale);
      final result = BookkeepingResult(transactionIds: const [
        1,
        2,
        3,
        4
      ], savedBills: const [
        BillInfo(amount: -10, type: BillType.expense, currency: 'CNY'),
        BillInfo(amount: -20, type: BillType.expense, currency: 'USD'),
        BillInfo(amount: 30, type: BillType.income, currency: 'CNY'),
        BillInfo(amount: 40, type: BillType.transfer, currency: 'EUR'),
      ], failedCount: 1, attachmentFailureCount: 1);
      final feedback =
          bookkeepingFeedback(l, result, postProcessingFailed: true);
      expect(feedback, contains('${l.aiTypeExpense} CNY 10.00'));
      expect(feedback, contains('${l.aiTypeExpense} USD 20.00'));
      expect(feedback, contains('${l.aiTypeIncome} CNY 30.00'));
      expect(feedback, contains('${l.appLinkTypeTransfer} EUR 40.00'));
      expect(feedback, contains(l.aiBillingFailedCount(1)));
      expect(feedback, contains(l.aiBillingAttachmentFailedCount(1)));
      expect(feedback, contains(l.aiBillingPostProcessingPending));
      expect(feedback, isNot(contains('¥')));
      expect(feedback, isNot(contains('×')));
    });
  }
  test('previously recorded payments are not counted as new amounts', () {
    final l = lookupAppLocalizations(const Locale('zh'));
    final result = BookkeepingResult(transactionIds: const [
      1
    ], reusedTransactionIds: const [
      1
    ], savedBills: const [
      BillInfo(amount: -50, type: BillType.expense, currency: 'CNY')
    ]);
    final feedback = bookkeepingFeedback(l, result);
    expect(feedback, l.aiBillingAlreadySavedCount(1));
    expect(feedback, isNot(contains('50.00')));
  });
}
