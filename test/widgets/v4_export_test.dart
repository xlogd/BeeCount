import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/l10n/app_localizations_en.dart';
import 'package:beecount/models/transaction_export_column.dart';
import 'package:beecount/pages/data/export_page.dart';
import 'package:beecount/pages/data/export/bindings/export_csv.dart';
import 'package:beecount/pages/data/export/bindings/export_platform.dart';
import 'package:beecount/dev/component_gallery/bindings/export_preview.dart';
import 'package:beecount/dev/component_gallery/export_sample.dart';
import 'package:beecount/providers.dart';
import 'package:beecount_business_ui/transaction_export.dart';
import 'package:beecount_ui/beecount_ui.dart';
import 'package:csv/csv.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Platform implements TransactionExportPlatform {
  _Platform({this.shareAfterSave = false});
  @override
  final bool shareAfterSave;
  String? csv, path, sharedPath, sharedText;
  int writes = 0;
  bool failWrite = false, failShare = false;
  Completer<void>? gate;
  @override
  Future<String> exportDirectory() async {
    if (gate != null) await gate!.future;
    return shareAfterSave ? '/QA/Documents' : '/QA/Download/BeeCount';
  }

  @override
  Future<void> writeCsv(String target, String content) async {
    writes++;
    if (failWrite) throw StateError('QA write denied');
    path = target;
    csv = content;
  }

  @override
  Future<void> shareCsv(String target, String text) async {
    if (failShare) throw StateError('QA share unavailable');
    sharedPath = target;
    sharedText = text;
  }
}

class _TrackedRepository extends LocalRepository {
  _TrackedRepository(super.db);
  final tagBatches = <int>[];
  final attachmentBatches = <int>[];

  @override
  Future<Map<int, List<Tag>>> getTagsForTransactions(List<int> ids) {
    tagBatches.add(ids.length);
    return super.getTagsForTransactions(ids);
  }

  @override
  Future<Map<int, List<TransactionAttachment>>> getAttachmentsForTransactions(
      List<int> ids) {
    attachmentBatches.add(ids.length);
    return super.getAttachmentsForTransactions(ids);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final l = AppLocalizationsEn();
  late BeeDatabase db;
  late LocalRepository repo;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    await db.customStatement(
        "INSERT INTO ledgers(id,name,currency) VALUES(1,'QA current ledger','cny'),(2,'QA other ledger','USD')");
    await db.customStatement(
        "INSERT INTO accounts(id,ledger_id,name,currency) VALUES(1,1,'QA USD account','usd'),(2,1,'QA recipient','USD')");
    await db.customStatement(
        "INSERT INTO categories(id,name,kind,parent_id,level) VALUES(1,'QA parent','expense',NULL,1),(2,'QA child','expense',1,2),(3,'QA salary','income',NULL,1)");
  });
  tearDown(() async => db.close());

  Future<void> seed(
      {int id = 1,
      int ledgerId = 1,
      String type = 'expense',
      int? account = 1,
      int? category = 2,
      String? currency = 'eur',
      String note = 'QA note'}) async {
    await db.customStatement(
        'INSERT INTO transactions(id,ledger_id,type,amount,category_id,account_id,to_account_id,happened_at,note,currency_code) VALUES(?,?,?,?,?,?,?,?,?,?)',
        [
          id,
          ledgerId,
          type,
          12.345,
          category,
          account,
          type == 'transfer' ? 2 : null,
          DateTime(2026, 10, 25, 8, 9, 10).millisecondsSinceEpoch ~/ 1000,
          note,
          currency
        ]);
  }

  void scenario(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (t) async {
      try {
        await body(t);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        await t.pumpAndSettle();
      }
    });
  }

  Widget host(_Platform platform, {Widget page = const ExportPage()}) =>
      ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(repo),
            transactionExportPlatformProvider.overrideWithValue(platform)
          ],
          child: MaterialApp(
              theme: beeTheme(),
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: page));

  void screen(WidgetTester t, Size size) {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  Future<void> start(WidgetTester t) async {
    await t
        .ensureVisible(find.byKey(const ValueKey('transaction-export-action')));
    await t.tap(find.byKey(const ValueKey('transaction-export-action')));
    await t.pump();
  }

  Future<void> pumpTask(WidgetTester t) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await t.pump(const Duration(milliseconds: 30));
      if (find.byType(Dialog).evaluate().isNotEmpty) {
        await t.pump(const Duration(milliseconds: 300));
        return;
      }
    }
    fail('Export did not display its result dialog');
  }

  Future<void> dismiss(WidgetTester t) async {
    await t.tap(find.text(l.commonOk).last);
    await t.pumpAndSettle();
  }

  test('CSV保留12列顺序、当前账本、类型、分类层级、币种和转账账户', () async {
    await seed(note: 'Comma, quote " and\nnewline');
    await seed(id: 2, type: 'income', category: 3, currency: null);
    await seed(id: 3, type: 'transfer', category: null, currency: null);
    await seed(id: 4, account: null, category: null, currency: null);
    await seed(id: 5, ledgerId: 2, note: 'Other ledger excluded');
    await db.customStatement(
        "INSERT INTO tags(id,name) VALUES(1,'QA tag,one'),(2,'QA tag two')");
    await db.customStatement(
        'INSERT INTO transaction_tags(transaction_id,tag_id) VALUES(1,1),(1,2)');
    await db.customStatement(
        "INSERT INTO transaction_attachments(transaction_id,file_name,sort_order) VALUES(1,'qa-a.png',0),(1,'qa-b.jpg',1)");
    final before = await db.select(db.transactions).get();
    final progress = <double>[];
    final csv = await buildTransactionExportCsv(
        repo: repo, ledgerId: 1, l10n: l, onProgress: progress.add);
    final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false)
        .convert(csv);
    expect(rows.length, 5);
    expect(rows.every((row) => row.length == 12), isTrue);
    expect(rows.first, [
      l.exportCsvHeaderType,
      l.exportCsvHeaderCategory,
      l.exportCsvHeaderSubCategory,
      l.exportCsvHeaderAmount,
      l.exportCsvHeaderCurrency,
      l.exportCsvHeaderAccount,
      l.exportCsvHeaderFromAccount,
      l.exportCsvHeaderToAccount,
      l.exportCsvHeaderNote,
      l.exportCsvHeaderTime,
      l.exportCsvHeaderTags,
      l.exportCsvHeaderAttachments
    ]);
    final expense =
        rows.singleWhere((row) => row[8] == 'Comma, quote " and\nnewline');
    expect(expense, [
      l.exportTypeExpense,
      'QA parent',
      'QA child',
      '12.35',
      'EUR',
      'QA USD account',
      '',
      '',
      'Comma, quote " and\nnewline',
      '  2026-10-25 08:09:10  ',
      'QA tag,one,QA tag two',
      'qa-a.png,qa-b.jpg'
    ]);
    final income = rows.singleWhere((row) => row[0] == l.exportTypeIncome);
    expect(income.sublist(1, 8),
        ['QA salary', '', '12.35', 'USD', 'QA USD account', '', '']);
    final transfer = rows.singleWhere((row) => row[0] == l.exportTypeTransfer);
    expect(transfer.sublist(1, 8),
        ['', '', '12.35', 'USD', '', 'QA USD account', 'QA recipient']);
    final noAccount = rows
        .singleWhere((row) => row[0] == l.exportTypeExpense && row[5] == '');
    expect(noAccount[4], 'CNY');
    expect(csv, isNot(contains('Other ledger excluded')));
    expect(progress, [.25, 1]);
    expect(await db.select(db.transactions).get(), before);
    expect(exportTypeDisplayName(l, 'unknown'), 'unknown');
  });

  test('批量导出保留每50行进度更新且不截断交易', () async {
    for (var id = 1; id <= 51; id++) {
      await seed(id: id, note: 'QA batch $id');
    }
    final values = <double>[];
    final csv = await buildTransactionExportCsv(
        repo: repo, ledgerId: 1, l10n: l, onProgress: values.add);
    expect(values, [1 / 51, 1]);
    expect(const CsvToListConverter(eol: '\n').convert(csv).length, 52);
  });

  test('空账本仍导出本地化CSV表头', () async {
    final csv =
        await buildTransactionExportCsv(repo: repo, ledgerId: 2, l10n: l);
    expect(const CsvToListConverter(eol: '\n').convert(csv),
        [exportCsvHeaders(l)]);
  });

  test('原系统写入保留UTF-8 BOM与原CSV字节', () async {
    final temporary =
        await Directory.systemTemp.createTemp('beecount-export-unit-');
    try {
      final path = '${temporary.path}/qa.csv';
      await const SystemTransactionExportPlatform()
          .writeCsv(path, '分类,金额\n咖啡,12.00');
      final bytes = await File(path).readAsBytes();
      expect(bytes.take(3), [0xef, 0xbb, 0xbf]);
      expect(utf8.decode(bytes), '分类,金额\n咖啡,12.00');
    } finally {
      await temporary.delete(recursive: true);
    }
  });

  test('自定义表头和数据保持同一顺序，正确引用逗号、引号与换行', () async {
    await seed(note: '咖啡, "双份"\n第二行');
    final tracked = _TrackedRepository(db);
    final csv = await buildTransactionExportCsv(
        repo: tracked,
        ledgerId: 1,
        l10n: l,
        columns: [
          TransactionExportColumn.note,
          TransactionExportColumn.amount,
          TransactionExportColumn.type
        ]);
    final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false)
        .convert(csv);
    expect(rows, [
      [l.exportCsvHeaderNote, l.exportCsvHeaderAmount, l.exportCsvHeaderType],
      ['咖啡, "双份"\n第二行', '12.35', l.exportTypeExpense]
    ]);
    expect(tracked.tagBatches, isEmpty);
    expect(tracked.attachmentBatches, isEmpty);
  });

  test('开始导出后修改调用方列表不改变本次文件结构', () async {
    await seed();
    final selected = [
      TransactionExportColumn.note,
      TransactionExportColumn.amount
    ];
    final pending = buildTransactionExportCsv(
        repo: repo, ledgerId: 1, l10n: l, columns: selected);
    selected
      ..clear()
      ..add(TransactionExportColumn.type);
    final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false)
        .convert(await pending);
    expect(rows.first, [l.exportCsvHeaderNote, l.exportCsvHeaderAmount]);
    expect(rows.last, ['QA note', '12.35']);
  });

  test('仅导出一个可空字段时空值仍保留每笔交易的完整单元格', () async {
    await seed(note: '');
    await seed(id: 2, type: 'income', note: '');
    for (final column in [
      TransactionExportColumn.note,
      TransactionExportColumn.tags,
      TransactionExportColumn.attachments
    ]) {
      final csv = await buildTransactionExportCsv(
          repo: repo, ledgerId: 1, l10n: l, columns: [column]);
      final rows =
          const CsvToListConverter(eol: '\n', shouldParseNumbers: false)
              .convert(csv);
      expect(rows, [
        [exportCsvColumnLabel(l, column)],
        [''],
        ['']
      ]);
      expect(csv, endsWith('\n""\n""'));
    }
  });

  test('服务拒绝空列和重复列，空账本仍完成自定义表头与进度', () async {
    await expectLater(
        buildTransactionExportCsv(
            repo: repo, ledgerId: 1, l10n: l, columns: []),
        throwsArgumentError);
    await expectLater(
        buildTransactionExportCsv(repo: repo, ledgerId: 1, l10n: l, columns: [
          TransactionExportColumn.note,
          TransactionExportColumn.note
        ]),
        throwsArgumentError);
    final values = <double>[];
    final csv = await buildTransactionExportCsv(
        repo: repo,
        ledgerId: 1,
        l10n: l,
        columns: [TransactionExportColumn.amount],
        onProgress: values.add);
    expect(csv, l.exportCsvHeaderAmount);
    expect(values, [1]);
  });

  test('大批量标签附件查询分批且保留末行数据', () async {
    for (var id = 1; id <= 501; id++) {
      await seed(id: id, note: 'batch $id');
    }
    await db.customStatement("INSERT INTO tags(id,name) VALUES(1,'last tag')");
    await db.customStatement(
        'INSERT INTO transaction_tags(transaction_id,tag_id) VALUES(501,1)');
    await db.customStatement(
        "INSERT INTO transaction_attachments(transaction_id,file_name) VALUES(501,'last.png')");
    final tracked = _TrackedRepository(db);
    final csv = await buildTransactionExportCsv(
        repo: tracked,
        ledgerId: 1,
        l10n: l,
        columns: [
          TransactionExportColumn.note,
          TransactionExportColumn.tags,
          TransactionExportColumn.attachments
        ]);
    expect(tracked.tagBatches, [500, 1]);
    expect(tracked.attachmentBatches, [500, 1]);
    final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false)
        .convert(csv);
    expect(rows.length, 502);
    expect(rows.singleWhere((row) => row.first == 'batch 501'),
        ['batch 501', 'last tag', 'last.png']);
  });

  test('列偏好保留顺序、过滤未知或重复ID，并恢复无法识别的旧配置', () {
    expect(
        restoreTransactionExportColumns(null), defaultTransactionExportColumns);
    expect(restoreTransactionExportColumns([]), isEmpty);
    expect(
        restoreTransactionExportColumns(['note', 'unknown', 'amount', 'note']),
        [TransactionExportColumn.note, TransactionExportColumn.amount]);
    expect(restoreTransactionExportColumns(['obsolete']),
        defaultTransactionExportColumns);
  });

  test('系统写入失败不会留下半成品文件', () async {
    final temporary =
        await Directory.systemTemp.createTemp('beecount-export-atomic-');
    try {
      final target = Directory('${temporary.path}/blocked.csv');
      await target.create();
      await expectLater(
          const SystemTransactionExportPlatform()
              .writeCsv(target.path, 'Header\nValue'),
          throwsA(isA<FileSystemException>()));
      expect(await target.exists(), isTrue);
      expect(await File('${target.path}.part').exists(), isFalse);
    } finally {
      await temporary.delete(recursive: true);
    }
  });

  scenario('清空列禁用导出，重新勾选后只导出所选数据并记住选择', (t) async {
    screen(t, const Size(398, 1000));
    await seed();
    final platform = _Platform();
    await t.pumpWidget(host(platform));
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const ValueKey('export-columns-clear')));
    await t.tap(find.byKey(const ValueKey('export-columns-clear')));
    await t.pumpAndSettle();
    expect(find.text(l.exportColumnsEmpty), findsOneWidget);
    expect(
        t
            .widget<BeeTransactionExport>(find.byType(BeeTransactionExport))
            .onExport,
        isNull);
    expect(platform.writes, 0);
    await t.ensureVisible(find.byKey(const ValueKey('export-column-amount')));
    await t.tap(find.byKey(const ValueKey('export-column-amount')));
    await t.pumpAndSettle();
    await start(t);
    await pumpTask(t);
    expect(
        const CsvToListConverter(eol: '\n', shouldParseNumbers: false)
            .convert(platform.csv!),
        [
          [l.exportCsvHeaderAmount],
          ['12.35']
        ]);
    await dismiss(t);
    expect(
        (await SharedPreferences.getInstance())
            .getStringList(transactionExportColumnsPreferenceKey),
        ['amount']);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pumpAndSettle();
    await t.pumpWidget(host(platform));
    await t.pumpAndSettle();
    expect(
        t.widget<BeeExportColumns>(find.byType(BeeExportColumns)).selectedIds,
        ['amount']);
    await t.ensureVisible(find.byKey(const ValueKey('export-columns-reset')));
    await t.tap(find.byKey(const ValueKey('export-columns-reset')));
    await t.pumpAndSettle();
    expect(
        t.widget<BeeExportColumns>(find.byType(BeeExportColumns)).selectedIds,
        TransactionExportColumn.values.map((column) => column.name));
  });

  scenario('恢复并调整列顺序，导出过程中锁定选择且使用捕获的顺序', (t) async {
    screen(t, const Size(398, 1000));
    SharedPreferences.setMockInitialValues({
      transactionExportColumnsPreferenceKey: ['amount', 'note', 'type']
    });
    await seed();
    final platform = _Platform()..gate = Completer<void>();
    await t.pumpWidget(host(platform));
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const ValueKey('export-columns-order')));
    await t.tap(find.text(l.exportColumnsOrder));
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const ValueKey('export-column-up-note')));
    await t.tap(find.byKey(const ValueKey('export-column-up-note')));
    await t.pumpAndSettle();
    expect(
        t.widget<BeeExportColumns>(find.byType(BeeExportColumns)).selectedIds,
        ['note', 'amount', 'type']);
    await start(t);
    expect(t.widget<BeeExportColumns>(find.byType(BeeExportColumns)).onChanged,
        isNull);
    platform.gate!.complete();
    await pumpTask(t);
    expect(
        const CsvToListConverter(eol: '\n', shouldParseNumbers: false)
            .convert(platform.csv!)
            .first,
        [
          l.exportCsvHeaderNote,
          l.exportCsvHeaderAmount,
          l.exportCsvHeaderType
        ]);
    await dismiss(t);
  });

  for (final brightness in Brightness.values) {
    scenario('可选列编辑器320宽1.4倍字号展开排序无溢出 $brightness', (t) async {
      screen(t, const Size(320, 568));
      final platform = _Platform();
      await t.pumpWidget(ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(repo),
            transactionExportPlatformProvider.overrideWithValue(platform),
          ],
          child: MaterialApp(
            theme: beeTheme(brightness: brightness),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(1.4)),
                child: child!),
            home: const ExportPage(),
          )));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const ValueKey('export-columns-order')));
      await t.tap(find.text(l.exportColumnsOrder));
      await t.pumpAndSettle();
      await t.ensureVisible(
          find.byKey(const ValueKey('export-column-up-category')));
      await t.tap(find.byKey(const ValueKey('export-column-up-category')));
      await t.pumpAndSettle();
      expect(
          t
              .widget<BeeExportColumns>(find.byType(BeeExportColumns))
              .selectedIds
              .first,
          'category');
      expect(t.takeException(), isNull);
    });

    scenario('纯导出卡320宽1.4倍长文本无溢出 $brightness', (t) async {
      screen(t, const Size(320, 568));
      var calls = 0;
      await t.pumpWidget(MaterialApp(
          theme: beeTheme(brightness: brightness),
          home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
              child: Scaffold(
                  body: SingleChildScrollView(
                      padding: const EdgeInsets.all(17),
                      child: BeeTransactionExport(
                          description: l.exportDescription,
                          ledgerLabel: l.configIncludeLedgers,
                          ledgerName:
                              'QA ledger with a sufficiently long Unicode name 账本',
                          fieldLabels: exportCsvHeaders(l),
                          actionLabel: l.exportButtonIOS,
                          savedMessage: l.exportSavedTo(
                              '/QA/Documents/BeeCount/a-long-export-file-name.csv'),
                          onExport: () => calls++))))));
      await t.pumpAndSettle();
      await start(t);
      expect(calls, 1);
      expect(t.takeException(), isNull);
    });
  }

  scenario('导出忙碌禁止重复提交，完成后保留文件名、实际CSV和保存提示', (t) async {
    screen(t, const Size(398, 1000));
    await seed();
    final platform = _Platform()..gate = Completer<void>();
    await t.pumpWidget(host(platform));
    await t.pumpAndSettle();
    await start(t);
    final button = find.descendant(
        of: find.byKey(const ValueKey('transaction-export-action')),
        matching: find.byType(FilledButton));
    expect(t.widget<FilledButton>(button).onPressed, isNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    platform.gate!.complete();
    await pumpTask(t);
    expect(platform.writes, 1);
    expect(
        platform.path!.replaceAll('\\', '/'),
        matches(
            RegExp(r'/QA/Download/BeeCount/beecount_\d{8}_\d{6}_\d{6}\.csv')));
    expect(platform.csv, contains('QA parent'));
    expect(platform.sharedPath, isNull);
    expect(find.text(l.exportSuccessTitle), findsOneWidget);
    await dismiss(t);
    expect(find.text(l.exportSavedTo(platform.path!)), findsOneWidget);
    expect(t.widget<FilledButton>(button).onPressed, isNotNull);
    expect(t.takeException(), isNull);
  });

  scenario('iOS分享契约保留路径、文案与系统面板关闭后成功提示', (t) async {
    screen(t, const Size(398, 1000));
    final platform = _Platform(shareAfterSave: true);
    await t.pumpWidget(host(platform));
    await t.pumpAndSettle();
    expect(find.text(l.exportButtonIOS), findsOneWidget);
    await start(t);
    await pumpTask(t);
    expect(platform.sharedPath, platform.path);
    expect(platform.sharedText, l.exportShareText);
    expect(platform.path!.replaceAll('\\', '/'), startsWith('/QA/Documents/'));
    await dismiss(t);
    expect(t.takeException(), isNull);
  });

  scenario('写入错误保留可重试状态、错误对话框和页面错误信息', (t) async {
    screen(t, const Size(398, 1000));
    final platform = _Platform()..failWrite = true;
    await t.pumpWidget(host(platform));
    await t.pumpAndSettle();
    await start(t);
    await pumpTask(t);
    expect(find.text(l.exportFailedTitle), findsNWidgets(2));
    await dismiss(t);
    expect(find.textContaining('QA write denied'), findsOneWidget);
    platform.failWrite = false;
    await start(t);
    await pumpTask(t);
    expect(platform.writes, 2);
    expect(find.text(l.exportSuccessTitle), findsOneWidget);
    await dismiss(t);
    expect(find.textContaining('QA write denied'), findsNothing);
  });

  scenario('分享失败保留已保存路径且恢复重试', (t) async {
    screen(t, const Size(398, 1000));
    final platform = _Platform(shareAfterSave: true)..failShare = true;
    await t.pumpWidget(host(platform));
    await t.pumpAndSettle();
    await start(t);
    await pumpTask(t);
    expect(platform.path, isNotNull);
    await dismiss(t);
    expect(find.text(l.exportSavedTo(platform.path!)), findsOneWidget);
    expect(find.textContaining('QA share unavailable'), findsOneWidget);
  });

  scenario('退出页面后异步导出完成不会对已销毁页面setState', (t) async {
    screen(t, const Size(398, 1000));
    final platform = _Platform()..gate = Completer<void>();
    await t.pumpWidget(host(platform));
    await t.pumpAndSettle();
    await start(t);
    await t.pumpWidget(const SizedBox.shrink());
    platform.gate!.complete();
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  scenario('只读真实预览与受控样例均不调用平台导出', (t) async {
    screen(t, const Size(398, 1000));
    final platform = _Platform();
    await t.pumpWidget(host(platform,
        page: const Scaffold(
            body: SingleChildScrollView(child: ExportPreview()))));
    await t.pumpAndSettle();
    expect(find.text('QA current ledger'), findsOneWidget);
    expect(
        t
            .widget<BeeTransactionExport>(find.byType(BeeTransactionExport))
            .onExport,
        isNull);
    await t.pumpWidget(host(platform,
        page: const Scaffold(
            body: SingleChildScrollView(child: ExportSample()))));
    await t.pumpAndSettle();
    await start(t);
    await t.pumpAndSettle();
    expect(platform.writes, 0);
    expect(platform.sharedPath, isNull);
    expect(t.takeException(), isNull);
  });
}
