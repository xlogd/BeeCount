import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/data/repositories/transaction_repository.dart';
import 'package:beecount/services/data_import_service.dart';
import 'package:beecount/services/import/transaction_zip.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

Uint8List zip(String csv, Map<String, String> files) {
  final bundle = Archive();
  for (final entry in {'transactions.csv': csv, ...files}.entries) {
    final bytes = utf8.encode(entry.value);
    bundle.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(bundle)!);
}

class _FailingRepository extends LocalRepository {
  _FailingRepository(super.db);

  @override
  Future<List<int>> insertTransactionsBatchWithRelations({
    required List<TransactionsCompanion> transactions,
    Map<int, List<int>> tagIdsByIndex = const {},
    Map<int, List<BatchAttachmentData>> attachmentsByIndex = const {},
    bool recordChanges = true,
  }) async {
    throw StateError('Batch did not commit');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const header = '序号,类型,金额,时间';
  const row = '1,支出,10,2026-10-20 12:00:00';
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('zip-import-test-');
  });
  tearDown(() => root.delete(recursive: true));

  test('a large ZIP missing its footer is rejected promptly from disk',
      () async {
    final file = File(p.join(root.path, 'truncated.zip'));
    final payload = Uint8List(5 * 1024 * 1024);
    final random = Random(113);
    for (var i = 0; i < payload.length; i++) {
      payload[i] = random.nextInt(256);
    }
    final archive = Archive()
      ..addFile(ArchiveFile('photo.png', payload.length, payload));
    final bytes = ZipEncoder().encode(archive)!;
    await file.writeAsBytes(bytes.sublist(0, bytes.length - 22));
    await expectLater(
      TransactionZip.read(temporaryDirectory: root, path: file.path)
          .timeout(const Duration(seconds: 3)),
      throwsA(isA<FormatException>().having(
          (error) => error.message, 'message', 'Incomplete ZIP archive')),
    );
    expect(root.listSync().map((item) => item.path), [file.path]);
  });

  for (final entry in [
    ('$header\n$row\n$row', <String, String>{}, 'duplicate sequence'),
    ('$header\n$row', {'附件/序号-3-orphan.png': 'png'}, 'cannot be matched'),
    ('$header\n$row', {'发票/序号-1-invalid.pdf': 'png'}, 'Invalid PDF'),
    (
      '$header\n$row',
      {'附件/序号-1-1-a.png': 'a', '发票/序号-1-1-b.pdf': '%PDF-'},
      'Ambiguous attachment order'
    ),
  ]) {
    test('rejects ${entry.$3} and removes temporary files', () async {
      await expectLater(
        TransactionZip.read(
            temporaryDirectory: root, bytes: zip(entry.$1, entry.$2)),
        throwsA(isA<FormatException>()
            .having((error) => error.message, 'message', contains(entry.$3))),
      );
      expect(root.listSync(), isEmpty);
    });
  }

  test('failed database batch removes its newly copied files', () async {
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = _FailingRepository(db);
    final ledgerId = await repo.createLedger(name: 'Target');
    final directory = await root.createTemp('attachments-');
    final original = File(p.join(directory.path, 'existing.png'));
    await original.writeAsString('existing');
    final bundle = await TransactionZip.read(
      temporaryDirectory: root,
      bytes: zip('$header\n$row', {'附件/序号-1-receipt.png': 'image'}),
    );
    try {
      final result = await bundle.import(() => dataImportService.importData(
            repo,
            ledgerId,
            ImportData(transactions: [
              ImportTransaction(
                type: 'expense',
                amount: 10,
                happenedAt: DateTime(2026, 10, 20),
                attachments: bundle.attachments[1],
              ),
            ]),
            attachmentDirectory: directory,
          ));
      expect(result.inserted, 0);
      expect(result.failed, 1);
      expect(await repo.getTransactionsByLedger(ledgerId), isEmpty);
      expect(directory.listSync().map((item) => item.path), [original.path]);
      expect(await original.readAsString(), 'existing');
    } finally {
      await bundle.dispose();
    }
  });
}
