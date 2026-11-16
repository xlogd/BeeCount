import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import '../../ai/core/bill_info.dart';

Future<String> imageBillingSourceHash(File source) async =>
    (await sha256.bind(source.openRead()).first).toString();

String imageBillingDraftKey(String ledgerIdentity, String sourceHash) => sha256
    .convert(utf8.encode('image-v1|$ledgerIdentity|$sourceHash'))
    .toString();

/// A warning key, never a rule that deletes or silently merges real payments.
String imageBillMatchKey(
        {required String type,
        required double amount,
        required DateTime time,
        required String note,
        required String currency}) =>
    jsonEncode([
      type,
      amount.abs().toStringAsFixed(8),
      time.toUtc().millisecondsSinceEpoch ~/ 1000,
      note.trim().replaceAll(RegExp(r'\s+'), ' '),
      currency.toUpperCase()
    ]);

class ImageBillingReview {
  const ImageBillingReview(
      {required this.bills,
      this.alreadySaved = const {},
      this.suspectedDuplicates = const {}});
  final List<BillInfo> bills;
  final Set<int> alreadySaved;
  final Set<int> suspectedDuplicates;
  Set<int> get defaultSelection => {
        for (var i = 0; i < bills.length; i++)
          if (!alreadySaved.contains(i) && !suspectedDuplicates.contains(i)) i,
      };
}

typedef ImageBillingReviewer = Future<Set<int>?> Function(
    ImageBillingReview review);
