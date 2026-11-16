import 'dart:async';
import 'dart:io';

import 'package:beecount/ai/core/ai_extraction_context.dart';
import 'package:beecount/ai/core/ai_extraction_engine.dart';
import 'package:beecount/ai/core/bill_info.dart';
import 'package:beecount/cloud/sync/change_tracker.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/services/ai/ai_bookkeeper.dart';
import 'package:beecount/services/ai/bookkeeping_result.dart';
import 'package:beecount/services/ai/image_billing_source.dart';
import 'package:beecount/services/billing/bill_creation_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Engine implements AiExtractionEngine {
  List<BillInfo> bills;
  int calls = 0;
  Completer<void>? gate;
  final entered = Completer<void>();
  _Engine(this.bills);
  @override
  Future<List<BillInfo>> extractFromImage(
      File image, AiExtractionContext context,
      {String billGuard = ''}) async {
    calls++;
    if (!entered.isCompleted) entered.complete();
    if (gate != null) await gate!.future;
    return bills;
  }

  @override
  Future<List<BillInfo>> extractFromText(
          String text, AiExtractionContext context,
          {String billGuard = ''}) async =>
      bills;
  @override
  Future<AudioExtractionResult> extractFromAudio(
          File file, AiExtractionContext context) async =>
      const AudioExtractionResult();
  @override
  Future<String?> speechToText(File audio) async => null;
}

BillInfo _bill(double amount, String note) => BillInfo(
    amount: -amount,
    type: BillType.expense,
    time: DateTime(2026, 11, 15, 8, 9, 32),
    note: note,
    category: '水电',
    currency: 'CNY');

class _MetadataFailingRepo extends LocalRepository {
  _MetadataFailingRepo(super.db);
  @override
  Future<Account?> getAccount(int id) async {
    if ((await db.select(db.transactions).get()).length > 6) {
      throw StateError('synthetic account metadata failure after commit');
    }
    return super.getAccount(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BeeDatabase db;
  late LocalRepository repo;
  late _Engine extraction;
  late int ledgerId;
  late List<Transaction> existing;
  late AiBookkeeper bookkeeper;
  AiBookkeeper createBookkeeper([LocalRepository? override]) {
    final repository = override ?? repo;
    return AiBookkeeper(
        repository: repository,
        engine: extraction,
        persister: BillCreationService(repository));
  }

  Future<BookkeepingResult> record(
          {String source = 'receipt-source',
          ImageBillingReviewer? review,
          Future<void> Function(int, int)? onSaved}) =>
      bookkeeper.fromImage(
          image: File('synthetic-image'),
          ledgerId: ledgerId,
          sourceFingerprint: source,
          billingTypes: const ['image', 'ai'],
          review: review,
          onSaved: onSaved);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db, changeTracker: ChangeTracker(db));
    ledgerId = await repo.createLedger(name: 'Synthetic safety ledger');
    await repo.createCategory(name: '水电', kind: 'expense');
    for (var i = 0; i < 6; i++) {
      await repo.addTransaction(
          ledgerId: ledgerId,
          type: 'expense',
          amount: 100.0 + i,
          happenedAt: DateTime(2026, 10, 1 + i),
          note: 'old-$i');
    }
    existing = await db.select(db.transactions).get();
    extraction = _Engine([_bill(50, 'electricity')]);
    bookkeeper = createBookkeeper();
  });
  tearDown(() async {
    try {
      final all = await db.select(db.transactions).get();
      for (final old in existing) {
        expect(all.singleWhere((tx) => tx.id == old.id), old);
        expect(all.where((tx) => tx.note == old.note), hasLength(1));
      }
    } finally {
      await db.close();
    }
  });
  Future<int> count() async => (await db.select(db.transactions).get()).length;

  test('same-source concurrent requests extract and insert only once',
      () async {
    extraction.gate = Completer<void>();
    final first = record();
    await extraction.entered.future;
    final second = record();
    extraction.gate!.complete();
    final results = await Future.wait([first, second]);
    expect(extraction.calls, 1);
    expect(results.first.transactionIds, results.last.transactionIds);
    expect(await count(), 7);
  });

  test('retry after bookkeeper recreation reuses the saved extraction and IDs',
      () async {
    final first = await record();
    extraction.bills = [_bill(999, 'must never be re-extracted')];
    bookkeeper = createBookkeeper();
    final retry = await record();
    expect(extraction.calls, 1);
    expect(retry.transactionIds, first.transactionIds);
    expect(retry.createdCount, 0);
    expect(retry.reusedTransactionIds, first.transactionIds);
    expect(await count(), 7);
  });

  test('partial retry creates only the failed item', () async {
    extraction.bills = [_bill(50, 'electricity'), _bill(5, 'bus')];
    await db.customStatement('''CREATE TEMP TRIGGER reject_bus
      BEFORE INSERT ON transactions WHEN NEW.note = 'bus'
      BEGIN SELECT RAISE(ABORT, 'synthetic item failure'); END''');
    final first = await record();
    expect(first.createdCount, 1);
    expect(first.failedCount, 1);
    await db.customStatement('DROP TRIGGER reject_bus');
    extraction.bills = [_bill(999, 'untrusted retry response')];
    bookkeeper = createBookkeeper();
    final retry = await record();
    expect(retry.createdCount, 1);
    expect(retry.reusedTransactionIds, first.transactionIds);
    expect(retry.failedCount, 0);
    expect(extraction.calls, 1);
    expect(await count(), 8);
  });

  test('change-log failure rolls back the financial row and retry saves once',
      () async {
    await db.customStatement('''CREATE TEMP TRIGGER reject_change
      BEFORE INSERT ON local_changes WHEN NEW.entity_type = 'transaction'
      BEGIN SELECT RAISE(ABORT, 'synthetic change failure'); END''');
    final first = await record();
    expect(first.success, isFalse);
    expect(first.failedCount, 1);
    expect(await count(), 6);
    await db.customStatement('DROP TRIGGER reject_change');
    expect((await record()).createdCount, 1);
    expect(await count(), 7);
  });

  test('ambiguous background response requires review without writing',
      () async {
    extraction.bills = [_bill(50, 'electricity'), _bill(50, 'electricity')];
    final result = await record();
    expect(result.needsReview, isTrue);
    expect(result.success, isFalse);
    expect(await count(), 6);
  });

  test('review can explicitly retain two legitimate identical payments',
      () async {
    extraction.bills = [_bill(50, 'electricity'), _bill(50, 'electricity')];
    final result = await record(review: (review) async {
      expect(review.defaultSelection, {0});
      expect(review.suspectedDuplicates, {1});
      return {0, 1};
    });
    expect(result.createdCount, 2);
    expect(result.transactionIds.toSet(), hasLength(2));
    expect(await count(), 8);
  });

  test('old bills returned with the new receipt are unselected by default',
      () async {
    final old = existing.first;
    extraction.bills = [
      BillInfo(
          amount: -old.amount,
          type: BillType.expense,
          time: old.happenedAt,
          note: old.note,
          currency: old.currencyCode),
      _bill(50, 'electricity')
    ];
    final result = await record(review: (review) async {
      expect(review.suspectedDuplicates, {0});
      expect(review.defaultSelection, {1});
      return review.defaultSelection;
    });
    expect(result.createdCount, 1);
    expect(await count(), 7);
  });

  test('cancelled review writes nothing and allows a fresh crop/extraction',
      () async {
    final cancelled = await record(review: (_) async => null);
    expect(cancelled.cancelled, isTrue);
    expect(await count(), 6);
    expect(await db.select(db.imageBillingDrafts).get(), isEmpty);
    extraction.bills = [_bill(25, 'new crop')];
    final result = await record(review: (_) async => {0});
    expect(result.firstBill!.amount, -25);
    expect(extraction.calls, 2);
    expect(await count(), 7);
  });

  test(
      'attachment failure remains a saved payment with a visible failure count',
      () async {
    var callbacks = 0;
    final result = await record(onSaved: (_, __) async {
      callbacks++;
      throw StateError('synthetic attachment failure');
    });
    expect(result.createdCount, 1);
    expect(result.attachmentFailureCount, 1);
    final retry = await record(onSaved: (_, __) async => callbacks++);
    expect(retry.createdCount, 0);
    expect(callbacks, 1);
    expect(await count(), 7);
  });

  test('metadata read failure after commit never reports financial failure',
      () async {
    final repository = _MetadataFailingRepo(db);
    await repository.createAccount(ledgerId: ledgerId, name: '花呗');
    extraction.bills = [_bill(50, 'electricity').copyWith(account: '花呗')];
    bookkeeper = createBookkeeper(repository);
    final result = await record();
    expect(result.createdCount, 1);
    expect(result.failedCount, 0);
    expect(await count(), 7);
  });

  test('same image remains independently recordable in another ledger',
      () async {
    await record();
    final another = await repo.createLedger(name: 'Another synthetic ledger');
    final result = await bookkeeper.fromImage(
        image: File('synthetic-image'),
        ledgerId: another,
        sourceFingerprint: 'receipt-source',
        billingTypes: const ['image']);
    expect(result.createdCount, 1);
    expect(await count(), 8);
  });

  test('repository explicit identity stays unique across concurrent callers',
      () async {
    Future<int> add() => repo.addTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 50,
        happenedAt: DateTime(2026, 11, 15),
        syncId: 'stable-image-item');
    final ids = await Future.wait([add(), add()]);
    expect(ids.toSet(), hasLength(1));
    expect(await count(), 7);
    final changes = await (db.select(db.localChanges)
          ..where((row) => row.entitySyncId.equals('stable-image-item')))
        .get();
    expect(changes, hasLength(1));
  });
}
