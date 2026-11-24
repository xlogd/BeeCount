import 'dart:io';

import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
      'v33 upgrade adds retry storage and preserves existing transaction identity',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('beecount-image-migration-');
    final file = File('${directory.path}/synthetic.sqlite');
    var db = BeeDatabase.forTesting(NativeDatabase(file));
    try {
      var repo = LocalRepository(db);
      final ledger = await repo.createLedger(name: 'Synthetic migration');
      final id = await repo.addTransaction(
          ledgerId: ledger,
          type: 'expense',
          amount: 50,
          happenedAt: DateTime(2026, 11, 15),
          note: 'existing electricity');
      final before = (await repo.getTransactionById(id))!;
      // Remove later additions to reproduce the v33 layout.
      await db.customStatement('DROP TABLE image_billing_drafts');
      await db.customStatement('ALTER TABLE transactions DROP COLUMN invoice_pending');
      await db.customStatement('PRAGMA user_version = 33');
      await db.close();
      db = BeeDatabase.forTesting(NativeDatabase(file));
      repo = LocalRepository(db);
      expect(await repo.getTransactionById(id), before);
      expect(
          (await db.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          35);
      await repo.saveImageBillingDraft(
          sourceKey: 'source', ledgerId: ledger, billsJson: '[]');
      await db.close();
      db = BeeDatabase.forTesting(NativeDatabase(file));
      repo = LocalRepository(db);
      expect(await repo.getImageBillingDraft('source'), '[]');
      expect(await repo.getTransactionById(id), before);
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });

  test(
      'draft follows ledger reassignment and is removed atomically with its ledger',
      () async {
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    try {
      final repo = LocalRepository(db);
      final ledger = await repo.createLedger(name: 'Synthetic ownership');
      await repo.saveImageBillingDraft(
          sourceKey: 'source', ledgerId: ledger, billsJson: '[]');
      await repo.reassignLedgerId(fromId: ledger, toId: ledger + 100);
      expect((await db.select(db.imageBillingDrafts).get()).single.ledgerId,
          ledger + 100);
      await repo.deleteLedger(ledger + 100);
      expect(await db.select(db.imageBillingDrafts).get(), isEmpty);
    } finally {
      await db.close();
    }
  });
}
