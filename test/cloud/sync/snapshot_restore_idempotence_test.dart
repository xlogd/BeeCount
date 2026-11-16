import 'dart:convert';

import 'package:beecount/cloud/sync/change_tracker.dart';
import 'package:beecount/cloud/sync/sync_engine.dart';
import 'package:beecount/cloud/transactions_json.dart';
import 'package:beecount/cloud/transactions_sync_manager.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as cloud;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_fakes/fake_beecount_cloud_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BeeDatabase db;
  late LocalRepository repo;
  late FakeBeeCountCloudProvider provider;
  late SyncEngine engine;
  late int ledgerId;
  late String ledgerSyncId;
  late List<Transaction> before;
  late Map<String, dynamic> snapshot;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    final tracker = ChangeTracker(db);
    repo = LocalRepository(db, changeTracker: tracker);
    provider = FakeBeeCountCloudProvider();
    engine = SyncEngine(
        db: db, repo: repo, provider: provider, changeTracker: tracker);
    ledgerId = await repo.createLedger(name: 'Synthetic restore');
    ledgerSyncId = (await repo.getLedgerById(ledgerId))!.syncId!;
    for (var i = 0; i < 7; i++) {
      await repo.addTransaction(
          ledgerId: ledgerId,
          type: 'expense',
          amount: i == 6 ? 50 : 100.0 + i,
          happenedAt: DateTime(2026, 11, i + 1),
          note: i == 6 ? 'image electricity' : 'unrelated-$i');
    }
    before = await db.select(db.transactions).get();
    snapshot = jsonDecode(await exportTransactionsJson(db, ledgerId))
        as Map<String, dynamic>;
    await provider.storage
        .upload(path: ledgerSyncId, data: jsonEncode(snapshot));
  });
  tearDown(() async {
    try {
      final all = await db.select(db.transactions).get();
      for (final old in before) {
        expect(all.singleWhere((tx) => tx.id == old.id), old);
        expect(all.where((tx) => tx.syncId == old.syncId), hasLength(1));
      }
    } finally {
      engine.dispose();
      await db.close();
    }
  });

  test(
      'empty incremental restore fallback leaves seven existing rows unchanged',
      () async {
    for (var i = 0; i < 3; i++) {
      final result =
          await engine.downloadAndRestoreToCurrentLedger(ledgerId: ledgerId);
      expect(result.inserted, 0);
      expect(await db.select(db.transactions).get(), before);
    }
  });

  test('backup-manager download also merges existing identities', () async {
    await provider.storage
        .upload(path: 'ledger_$ledgerId.json', data: jsonEncode(snapshot));
    final manager = TransactionsSyncManager(
        config: const cloud.CloudServiceConfig(
            type: cloud.CloudBackendType.webdav,
            name: 'Synthetic',
            webdavUrl: 'https://qa.invalid',
            webdavUsername: 'synthetic',
            webdavPassword: 'synthetic'),
        db: db,
        repo: repo,
        provider: provider);
    expect(
        (await manager.downloadAndRestoreToCurrentLedger(ledgerId: ledgerId))
            .inserted,
        0);
    expect(await db.select(db.transactions).get(), before);
  });

  test(
      'merge adds only missing identities and retains legitimate same-value payments',
      () async {
    final sample =
        Map<String, dynamic>.from((snapshot['items'] as List).first as Map);
    (snapshot['items'] as List).addAll([
      {...sample, 'syncId': 'new-payment-1'},
      {...sample, 'syncId': 'new-payment-2'},
    ]);
    snapshot['count'] = 9;
    await provider.storage
        .upload(path: ledgerSyncId, data: jsonEncode(snapshot));
    final first = await engine.runFullPull(ledgerId: ledgerId);
    expect(first.inserted, 2);
    expect(await db.select(db.transactions).get(), hasLength(9));
    expect((await engine.runFullPull(ledgerId: ledgerId)).inserted, 0);
    expect(await db.select(db.transactions).get(), hasLength(9));
  });

  test('legacy snapshot without identities cannot append to an existing ledger',
      () async {
    snapshot['version'] = 5;
    for (final item in snapshot['items'] as List) {
      (item as Map).remove('syncId');
    }
    await provider.storage
        .upload(path: ledgerSyncId, data: jsonEncode(snapshot));
    await expectLater(
        engine.runFullPull(ledgerId: ledgerId), throwsFormatException);
    expect(await db.select(db.transactions).get(), before);
  });

  test('duplicate snapshot identities are rejected before financial writes',
      () async {
    (snapshot['items'] as List).add((snapshot['items'] as List).first);
    snapshot['count'] = 8;
    await provider.storage
        .upload(path: ledgerSyncId, data: jsonEncode(snapshot));
    await expectLater(
        engine.runFullPull(ledgerId: ledgerId), throwsFormatException);
    expect(await db.select(db.transactions).get(), before);
  });

  test('failed snapshot batch rolls back rows and ledger metadata', () async {
    final sample =
        Map<String, dynamic>.from((snapshot['items'] as List).first as Map);
    snapshot['items'] = [
      {...sample, 'syncId': 'missing-1', 'note': 'good'},
      {...sample, 'syncId': 'missing-2', 'note': 'reject'},
    ];
    snapshot['count'] = 2;
    snapshot['ledgerName'] = 'Should roll back';
    await db.customStatement('''CREATE TEMP TRIGGER reject_snapshot
      BEFORE INSERT ON transactions WHEN NEW.note = 'reject'
      BEGIN SELECT RAISE(ABORT, 'synthetic restore failure'); END''');
    await provider.storage
        .upload(path: ledgerSyncId, data: jsonEncode(snapshot));
    await expectLater(engine.runFullPull(ledgerId: ledgerId), throwsStateError);
    expect((await repo.getLedgerById(ledgerId))!.name, 'Synthetic restore');
    expect(await db.select(db.transactions).get(), before);
  });

  test('transaction created after cache prime is found before a remote insert',
      () async {
    engine.activePullCache = LookupCache();
    await engine.activePullCache!.prime(db);
    final id = await repo.addTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 50,
        happenedAt: DateTime(2026, 11, 15),
        syncId: 'created-after-prime');
    final tx = (await repo.getTransactionById(id))!;
    await engine.applyRemoteChange(provider.pushFakeChange(
        entitySyncId: 'created-after-prime',
        ledgerId: ledgerSyncId,
        payload: {
          'type': 'expense',
          'amount': 50,
          'happenedAt': tx.happenedAt.toIso8601String(),
          'currencyCode': tx.currencyCode,
          'nativeAmount': tx.nativeAmount
        }));
    final matches = (await db.select(db.transactions).get())
        .where((row) => row.syncId == 'created-after-prime');
    expect(matches.single.id, id);
    expect(await db.select(db.transactions).get(), hasLength(8));
  });
}
