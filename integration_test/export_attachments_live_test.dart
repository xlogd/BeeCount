// Run only on a new, independently packaged QA emulator.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/main.dart' show MainApp;
import 'package:beecount/pages/data/export_page.dart';
import 'package:beecount/pages/main/home_page.dart';
import 'package:beecount/pages/main/mine_page.dart';
import 'package:beecount/pages/settings/data_management_page.dart';
import 'package:beecount/providers/database_providers.dart';
import 'package:beecount/providers/ui_state_providers.dart';
import 'package:beecount/services/attachment_service.dart';
import 'package:beecount_business_ui/transaction_export.dart';
import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _runId = String.fromEnvironment('QA_RUN_ID');
const _qaPackage = 'com.tntlikely.beecount.qa.dev.debug';
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL/nwAAAABJRU5ErkJggg==';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'production export UI packages renamed images without a CSV attachment column',
      (tester) async {
    expect((await PackageInfo.fromPlatform()).packageName, _qaPackage);
    expect(_runId.startsWith('beecount-export-qa-'), isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('cloud_active_type') ?? 'local', 'local');
    await prefs.setString('selected_language', 'zh');
    await prefs.setBool('welcome_shown', true);
    await prefs.setInt('current_ledger_id', 1);

    final db = BeeDatabase();
    final existing = await db.select(db.transactions).get();
    if (existing.isEmpty) {
      for (final table in db.allTables) {
        expect(await db.select(table).get(), isEmpty,
            reason: 'A fresh QA package is required: ${table.actualTableName}');
      }
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await db.customStatement(
          "INSERT INTO ledgers(id,name,currency) VALUES(1,'QA 导出验收','CNY')");
      await db.customStatement(
          "INSERT INTO categories(id,name,kind,parent_id,level) VALUES(1,'QA 餐饮','expense',NULL,1)");
      await db.customStatement(
          'INSERT INTO transactions(id,ledger_id,type,amount,category_id,happened_at,note) VALUES(1,1,\'expense\',18.50,1,?,\'午餐\'),(2,1,\'expense\',6.00,1,?,\'饮水\')',
          [now, now - 86400]);
    } else {
      expect(existing.map((row) => row.id), [1, 2]);
      expect(existing.map((row) => row.note), ['午餐', '饮水']);
    }
    final container =
        ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    final attachmentDir = await container
        .read(attachmentServiceProvider)
        .getAttachmentDirectory();
    final originalBytes = base64Decode(_png);
    for (final fileName in ['qa-first.png', 'qa-second.png']) {
      await File('${attachmentDir.path}/$fileName')
          .writeAsBytes(originalBytes, flush: true);
    }
    if (existing.isEmpty) {
      await db.customStatement(
          "INSERT INTO transaction_attachments(id,transaction_id,file_name,sort_order) VALUES(1,1,'qa-first.png',0),(2,1,'qa-second.png',1)");
    }
    final originalTransactions = await db.select(db.transactions).get();
    final exportDir = Directory('/storage/emulated/0/Download/BeeCount');
    final existingExports = exportDir.existsSync()
        ? exportDir
            .listSync()
            .whereType<File>()
            .map((file) => file.path)
            .toSet()
        : <String>{};

    await container.read(appSplashInitProvider.future);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container, child: const MainApp()));

    Future<void> waitFor(bool Function() ready, String label) async {
      for (var i = 0; i < 150; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (ready()) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      fail(
          'Timed out waiting for $label; Flutter error: ${tester.takeException()}');
    }

    await waitFor(() => find.byType(HomePage).evaluate().isNotEmpty, 'home');
    final l = AppLocalizations.of(tester.element(find.byType(HomePage)));
    expect(l.localeName, 'zh');
    await tester.tap(find.text(l.tabMine).last);
    await waitFor(() => find.byType(MinePage).evaluate().isNotEmpty, 'mine');
    await tester.ensureVisible(find.text(l.dataManagement).last);
    await tester.tap(find.text(l.dataManagement).last);
    await waitFor(() => find.byType(DataManagementPage).evaluate().isNotEmpty,
        'data management');
    await tester.ensureVisible(find.text(l.mineExport).last);
    await tester.tap(find.text(l.mineExport).last);
    await waitFor(
        () => find.byType(ExportPage).evaluate().isNotEmpty, 'export');
    expect(
        tester
            .widget<BeeExportColumns>(find.byType(BeeExportColumns))
            .selectedIds,
        contains('attachments'));
    await tester
        .ensureVisible(find.byKey(const ValueKey('transaction-export-action')));
    await tester.tap(find.byKey(const ValueKey('transaction-export-action')));
    await waitFor(
        () =>
            find.text(l.exportSuccessTitle).evaluate().isNotEmpty ||
            find.text(l.exportFailedTitle).evaluate().isNotEmpty,
        'export result');
    expect(find.text(l.exportSuccessTitle), findsOneWidget,
        reason: 'The production export action must complete on Android');

    final zipFiles = exportDir
        .listSync()
        .whereType<File>()
        .where((file) =>
            file.path.endsWith('.zip') && !existingExports.contains(file.path))
        .toList();
    expect(zipFiles, hasLength(1));
    final archive =
        ZipDecoder().decodeBytes(await zipFiles.single.readAsBytes());
    final csvBytes = archive.findFile('transactions.csv')!.content as List<int>;
    expect(csvBytes.take(3), [0xef, 0xbb, 0xbf]);
    final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false)
        .convert(utf8.decode(csvBytes));
    expect(rows, hasLength(3));
    expect(rows.first.first, l.exportCsvHeaderSequence);
    expect(rows.first, isNot(contains(l.exportCsvHeaderAttachments)));
    expect(rows[1].first, '1');
    expect(rows[2].first, '2');
    expect(rows[1], contains('午餐'));
    expect(rows[2], contains('饮水'));
    final images = archive.files
        .where((file) => file.name.startsWith('附件/'))
        .toList();
    expect(images.map((file) => file.name),
        ['附件/序号-1-1-午餐.png', '附件/序号-1-2-午餐.png']);
    for (final image in images) {
      expect(image.content, originalBytes);
    }
    expect(await db.select(db.transactions).get(), originalTransactions);
    binding.reportData = {
      'run_id': _runId,
      'status': 'PASS',
      'record_count': rows.length - 1,
      'image_count': images.length,
      'zip_path': zipFiles.single.path,
    };
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await db.close();
  });
}
