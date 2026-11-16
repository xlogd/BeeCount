import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/ai/bookkeeping_feedback.dart';
import '../../../services/ai/image_billing_source.dart';

Future<Set<int>?> showImageBillingReview(
    BuildContext context, ImageBillingReview review,
    {required String currency}) {
  final l = AppLocalizations.of(context);
  final selected = review.defaultSelection;
  return showModalBottomSheet<Set<int>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => StatefulBuilder(
        builder: (ctx, update) => SizedBox(
            height: MediaQuery.sizeOf(ctx).height * .8,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l.aiImageReviewTitle,
                                style: Theme.of(ctx).textTheme.titleLarge),
                            const SizedBox(height: 8),
                            Text(l.aiImageReviewHint),
                          ])),
                  Expanded(
                      child: ListView.builder(
                          itemCount: review.bills.length,
                          itemBuilder: (ctx, index) {
                            final bill = review.bills[index];
                            final saved = review.alreadySaved.contains(index);
                            final duplicate =
                                review.suspectedDuplicates.contains(index);
                            return CheckboxListTile(
                              key: ValueKey('image-billing-review-$index'),
                              value: selected.contains(index),
                              onChanged: saved
                                  ? null
                                  : (value) => update(() {
                                        if (value == true) {
                                          selected.add(index);
                                        } else {
                                          selected.remove(index);
                                        }
                                      }),
                              title: Text('${billingTypeLabel(l, bill.type)} '
                                  '${bill.currency ?? currency} ${(bill.amount?.abs() ?? 0).toStringAsFixed(2)}'),
                              subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (bill.note?.trim().isNotEmpty == true)
                                      Text(bill.note!),
                                    if (bill.time != null)
                                      Text(DateFormat('yyyy-MM-dd HH:mm:ss')
                                          .format(bill.time!.toLocal())),
                                    if (saved)
                                      Text(l.aiImageReviewAlreadySaved),
                                    if (duplicate && !saved)
                                      Text(l.aiImageReviewDuplicate,
                                          style: TextStyle(
                                              color: Theme.of(ctx)
                                                  .colorScheme
                                                  .error)),
                                  ]),
                            );
                          })),
                  SafeArea(
                      top: false,
                      child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(children: [
                            TextButton(
                                onPressed: () => Navigator.pop(sheetContext),
                                child: Text(l.commonCancel)),
                            const SizedBox(width: 12),
                            Expanded(
                                child: FilledButton(
                                    key: const ValueKey(
                                        'image-billing-review-save'),
                                    onPressed: selected.isEmpty
                                        ? null
                                        : () => Navigator.pop(sheetContext,
                                            Set<int>.unmodifiable(selected)),
                                    child: Text(
                                        l.aiImageReviewSave(selected.length)))),
                          ]))),
                ]))),
  );
}
