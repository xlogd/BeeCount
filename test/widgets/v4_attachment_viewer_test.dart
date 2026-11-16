import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/pages/attachment/attachment_preview_page.dart';
import 'package:beecount/providers.dart';
import 'package:beecount/services/attachment_service.dart';
import 'package:beecount/services/image_crop_service.dart';
import 'package:beecount_ui/beecount_ui.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Repository extends LocalRepository {
  _Repository(super.db);
  bool rejectDelete = false;
  @override
  Future<void> deleteAttachment(int id) {
    if (rejectDelete) throw StateError('Synthetic delete failure');
    return super.deleteAttachment(id);
  }
}

class _Cropper extends ImageCropService {
  File? result;
  bool fail = false;
  Completer<File?>? gate;
  @override
  Future<File?> crop(BuildContext context, File source,
      {ImageCropPurpose purpose = ImageCropPurpose.attachment,
      Color? primaryColor}) async {
    if (fail) throw StateError('Synthetic crop failure');
    return gate == null ? result : gate!.future;
  }
}

class _Attachments extends AttachmentService {
  _Attachments(super.ref, this.directory);
  final Directory directory;
  bool rejectDirectory = false;
  @override
  Future<Directory> getAttachmentDirectory() async {
    if (rejectDirectory) throw StateError('Synthetic directory failure');
    return directory;
  }

  @override
  Future<Directory> getThumbnailDirectory() async =>
      Directory('${directory.path}/thumbs')..createSync();
}

void main() {
  late Directory directory;
  late BeeDatabase db;
  late _Repository repo;
  late ProviderContainer container;
  late _Attachments service;
  late List<TransactionAttachment> rows;
  late List<File> pending;
  late _Cropper cropper;

  setUp(() async {
    SharedPreferences.setMockInitialValues(
        {'auto_sync': false, 'attachmentKeepOriginal': true});
    directory = await Directory.systemTemp.createTemp('beecount-v4-viewer-');
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = _Repository(db);
    await db.customStatement(
        "INSERT INTO ledgers (id,name,currency) VALUES (1,'QA','CNY')");
    await db.customStatement(
        "INSERT INTO transactions (id,ledger_id,type,amount) VALUES (1,1,'expense',10),(2,1,'income',20)");
    final picture = ui.PictureRecorder();
    ui.Canvas(picture).drawPaint(ui.Paint()..color = const Color(0xfffacd20));
    final recording = picture.endRecording();
    final image = await recording.toImage(40, 80);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    recording.dispose();
    pending = [];
    for (var i = 0; i < 2; i++) {
      final name = 'synthetic-$i.png';
      pending.add(await File('${directory.path}/$name')
          .writeAsBytes(bytes!.buffer.asUint8List()));
      await repo.createAttachment(
          transactionId: 1,
          fileName: name,
          fileSize: 2048,
          originalName: name,
          width: 40,
          height: 80,
          sortOrder: i);
    }
    // Another transaction shares the first physical file.
    await repo.createAttachment(transactionId: 2, fileName: 'synthetic-0.png');
    rows = await repo.getAttachmentsByTransaction(1);
    cropper = _Cropper();
    container = ProviderContainer(overrides: [
      imageCropServiceProvider.overrideWithValue(cropper),
      repositoryProvider.overrideWithValue(repo),
      attachmentServiceProvider
          .overrideWith((ref) => service = _Attachments(ref, directory)),
    ]);
    container.read(attachmentServiceProvider);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: beeTheme(),
            home: Builder(
                builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () => Navigator.push(context,
                            MaterialPageRoute<void>(builder: (_) => page)),
                        child: const Text('打开预览')))))));
    await tester.tap(find.text('打开预览'));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 30));
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // Native reads finish outside the fake clock; flush their callbacks before
    // removing temporary image files on Windows.
    for (var frame = 0; frame < 5; frame++) {
      tester.binding.imageCache.clear();
      tester.binding.imageCache.clearLiveImages();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  Future<File> cropFile(WidgetTester tester) async =>
      (await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder)
            .drawPaint(ui.Paint()..color = const Color(0xfffacd20));
        final picture = recorder.endRecording();
        final image = await picture.toImage(20, 40);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        return File('${directory.path}/cropped.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      }))!;

  Future<void> finishCrop(WidgetTester tester) async {
    for (var i = 0; i < 80; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
    }
    fail('Crop did not finish');
  }

  testWidgets('草稿裁剪更新父级列表，原图不修改且不写数据库', (tester) async {
    cropper.result = await cropFile(tester);
    List<File>? draft;
    await open(
        tester,
        AttachmentPreviewPage(
            attachments: const [],
            pendingFiles: pending,
            onPendingFilesChanged: (files) => draft = files));
    await tester.tap(find.byKey(const ValueKey('attachment-crop')));
    await finishCrop(tester);
    expect(draft!.map((file) => file.path),
        [cropper.result!.path, pending.last.path]);
    expect(await repo.getAttachmentsByTransaction(1), rows);
    expect(pending.first.existsSync(), isTrue);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('已保存附件裁剪保留ID与顺序，共享原图及其他交易不变', (tester) async {
    cropper.result = await cropFile(tester);
    await open(
        tester, const AttachmentPreviewPage.fromTransaction(transactionId: 1));
    final before = await repo.getAttachmentsByTransaction(2);
    await tester.tap(find.byKey(const ValueKey('attachment-crop')));
    await finishCrop(tester);
    final after = await repo.getAttachmentsByTransaction(1);
    expect(after, hasLength(2));
    expect(after.first.id, rows.first.id);
    expect(after.first.sortOrder, rows.first.sortOrder);
    expect(after.first.fileName, isNot(rows.first.fileName));
    expect((after.first.width, after.first.height), (20, 40));
    expect(await repo.getAttachmentsByTransaction(2), before);
    expect(pending.first.existsSync(), isTrue);
    expect(find.textContaining('20×40'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('取消裁剪保持草稿、数据库和当前图片不变', (tester) async {
    List<File>? changed;
    await open(
        tester,
        AttachmentPreviewPage(
            attachments: const [],
            pendingFiles: pending,
            onPendingFilesChanged: (files) => changed = files));
    await tester.tap(find.byKey(const ValueKey('attachment-crop')));
    await finishCrop(tester);
    expect(changed, isNull);
    expect(await repo.getAttachmentsByTransaction(1), rows);
    expect(find.text('1 / 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('裁剪失败显示错误并保留原附件', (tester) async {
    cropper.fail = true;
    await open(
        tester, const AttachmentPreviewPage.fromTransaction(transactionId: 1));
    await tester.tap(find.byKey(const ValueKey('attachment-crop')));
    await finishCrop(tester);
    expect(find.text('裁剪或保存图片失败，请重试。'), findsOneWidget);
    expect(await repo.getAttachmentsByTransaction(1), rows);
    expect(pending.first.existsSync(), isTrue);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('裁剪处理中禁止重复操作和系统返回，取消后恢复', (tester) async {
    cropper.gate = Completer<File?>();
    await open(
        tester, const AttachmentPreviewPage.fromTransaction(transactionId: 1));
    await tester.tap(find.byKey(const ValueKey('attachment-crop')));
    await tester.pump();
    expect(
        tester.widget<PopScope>(find.byType(PopScope).first).canPop, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(AttachmentPreviewPage), findsOneWidget);
    cropper.gate!.complete(null);
    await finishCrop(tester);
    expect(tester.widget<PopScope>(find.byType(PopScope).first).canPop, isTrue);
    expect(await repo.getAttachmentsByTransaction(1), rows);
    await close(tester);
  });

  testWidgets('真实附件加载、索引夹取、滑动与缩略图切换，保留缩放', (tester) async {
    await open(
        tester,
        const AttachmentPreviewPage.fromTransaction(
            transactionId: 1, initialIndex: 99));
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.text('2 KB · 40×80'), findsOneWidget);
    final zoom =
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer).first);
    expect(zoom.maxScale, 4);
    await tester.drag(find.byType(PageView), const Offset(650, 0));
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('2 / 2 · synthetic-1.png'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(await repo.getAttachmentsByTransaction(1), hasLength(2));
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('全屏附件区域与冻结 HTML 对齐，文件名和选中缩略图留白完整', (tester) async {
    tester.view.physicalSize = const Size(398, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(
        tester,
        Container(
            decoration: BoxDecoration(border: Border.all()),
            child:
                const AttachmentPreviewPage.fromTransaction(transactionId: 1)));
    final contract = jsonDecode(
        File('test/fixtures/v4-attachment-viewer-geometry.json')
            .readAsStringSync()) as Map<String, dynamic>;
    final boxes = contract['boxes'] as Map<String, dynamic>;
    for (final name in ['frame', 'toolbar', 'stage', 'footer', 'thumbnails']) {
      final actual =
          tester.getRect(find.byKey(ValueKey('attachment-viewer-$name')));
      final expected = boxes[name] as Map<String, dynamic>;
      expect(actual.left, closeTo(expected['x'] as num, 1), reason: name);
      expect(actual.top, closeTo(expected['y'] as num, 1), reason: name);
      expect(actual.width, closeTo(expected['width'] as num, 1), reason: name);
      expect(actual.height, closeTo(expected['height'] as num, 1),
          reason: name);
    }
    expect(find.text('synthetic-0.png'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('双指缩放实际改变图片矩阵，不误触关闭或切换并保持原附件', (tester) async {
    await open(
        tester,
        const AttachmentPreviewPage.fromTransaction(
            transactionId: 1, allowDelete: false));
    final viewer = find.byType(InteractiveViewer).first;
    final center = tester.getCenter(viewer);
    final left =
        await tester.startGesture(center - const Offset(40, 0), pointer: 1);
    final right =
        await tester.startGesture(center + const Offset(40, 0), pointer: 2);
    await tester.pump();
    await left.moveTo(center - const Offset(140, 0));
    await right.moveTo(center + const Offset(140, 0));
    await tester.pump(const Duration(milliseconds: 50));
    final transforms = tester.widgetList<Transform>(
        find.descendant(of: viewer, matching: find.byType(Transform)));
    expect(
        transforms.any((t) => t.transform.getMaxScaleOnAxis() > 1.5), isTrue);
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.byType(AttachmentPreviewPage), findsOneWidget);
    expect(await repo.getAttachmentsByTransaction(1), rows);
    expect(pending.every((file) => file.existsSync()), isTrue);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('删除取消不改数据，确认只删当前引用并保留共享图片', (tester) async {
    await open(
        tester, const AttachmentPreviewPage.fromTransaction(transactionId: 1));
    await tester.tap(find.bySemanticsLabel('删除').first);
    await tester.pumpAndSettle();
    expect(find.byType(BeeDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await repo.getAttachmentsByTransaction(1), hasLength(2));
    await tester.tap(find.bySemanticsLabel('删除').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(BeeButton, '删除'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pumpAndSettle();
    expect(find.text('1 / 1'), findsOneWidget);
    expect(await repo.getAttachmentsByTransaction(1), hasLength(1));
    expect(await repo.getAttachmentsByTransaction(2), hasLength(1));
    expect(pending.first.existsSync(), isTrue);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('服务删除失败保留图片与数据库，不能显示删除成功', (tester) async {
    repo.rejectDelete = true;
    await open(
        tester, const AttachmentPreviewPage.fromTransaction(transactionId: 1));
    await tester.tap(find.bySemanticsLabel('删除').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(BeeButton, '删除'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    expect(await repo.getAttachmentsByTransaction(1), hasLength(2));
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('待保存图片删除即时更新父级，系统返回不丢草稿且不删文件', (tester) async {
    List<File>? draft;
    await open(
        tester,
        AttachmentPreviewPage(
            attachments: const [],
            pendingFiles: pending,
            onPendingFilesChanged: (files) => draft = files));
    expect(find.text('待保存'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('删除').first);
    await tester.pumpAndSettle();
    expect(draft?.map((f) => f.path), [pending.last.path]);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('打开预览'), findsOneWidget);
    expect(draft?.map((f) => f.path), [pending.last.path]);
    expect(pending.first.existsSync(), isTrue);
    expect(await repo.getAttachmentsByTransaction(1), hasLength(2));
    await close(tester);
  });

  testWidgets('目录失败可重试，只读预览不提供新增与删除', (tester) async {
    service.rejectDirectory = true;
    await open(
        tester, AttachmentPreviewPage(attachments: rows, allowDelete: false));
    expect(find.text('重试'), findsOneWidget);
    expect(find.bySemanticsLabel('删除'), findsNothing);
    service.rejectDirectory = false;
    await tester.tap(find.text('重试'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.bySemanticsLabel('删除'), findsNothing);
    expect(find.bySemanticsLabel('添加图片'), findsNothing);
    expect(find.byKey(const ValueKey('attachment-crop')), findsNothing);
    expect(tester.takeException(), isNull);
    await close(tester);
  });
}
