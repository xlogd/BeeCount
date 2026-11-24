import 'dart:io';
import 'dart:ui' as ui;

import 'package:beecount/ai/core/ai_extraction_context.dart';
import 'package:beecount/ai/core/ai_extraction_engine.dart';
import 'package:beecount/ai/core/bill_info.dart';
import 'package:beecount/ai/providers/ai_provider_config.dart';
import 'package:beecount/ai/providers/ai_provider_manager.dart';
import 'package:beecount/cloud/sync_service.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/pages/attachment/attachment_crop_page.dart';
import 'package:beecount/providers.dart';
import 'package:beecount/providers/ai_chat_providers.dart';
import 'package:beecount/services/attachment_service.dart';
import 'package:beecount/services/ai/billing_image_service.dart';
import 'package:beecount/services/image_crop_service.dart';
import 'package:beecount/utils/image_billing_helper.dart';
import 'package:beecount_ui/beecount_ui.dart';
import 'package:crop_your_image/crop_your_image.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// The picker is replaced at its platform boundary in this test.
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Engine extends Mock implements AiExtractionEngine {}

class _Attachments extends Mock implements AttachmentService {}

class _Images extends BillingImageService {
  @override
  Future<BillingImageFiles> prepare(File file,
          {required bool keepOriginal}) async =>
      BillingImageFiles(file, file);
}

class _Picker extends ImagePickerPlatform {
  final String path;
  int calls = 0;
  _Picker(this.path);
  @override
  Future<XFile?> getImageFromSource(
      {required ImageSource source,
      ImagePickerOptions options = const ImagePickerOptions()}) async {
    calls++;
    return XFile(path);
  }
}

class _Crop extends ImageCropService {
  @override
  Future<File?> crop(BuildContext context, File source,
          {ImageCropPurpose purpose = ImageCropPurpose.attachment,
          Color? primaryColor}) async =>
      source;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(File('synthetic'));
  registerFallbackValue(AiExtractionContext.fallback);
  late BeeDatabase db;
  late LocalRepository repo;
  late Ledger ledger;
  late Directory directory;
  late _Picker picker;
  late ImagePickerPlatform previousPicker;
  late _Engine extraction;
  late ProviderContainer container;
  late BuildContext context;
  late WidgetRef widgetRef;
  late List<BillInfo> bills;
  var engineCalls = 0;
  late Future<void> operation;
  BillInfo bill(double amount, String note) => BillInfo(
      amount: -amount,
      type: BillType.expense,
      time: DateTime(2026, 11, 15, 8, 9, 32),
      note: note,
      currency: 'CNY');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AIProviderManager.updateProvider(
        AIServiceProviderConfig.zhipuDefault.copyWith(apiKey: 'synthetic'));
    await AIProviderManager.setCapabilityProvider(
        AICapabilityType.vision, 'zhipu_glm');
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    ledger = (await repo
        .getLedgerById(await repo.createLedger(name: 'Synthetic review')))!;
    directory = await Directory.systemTemp.createTemp('beecount-review-test-');
    final file = await File('${directory.path}/receipt.png')
        .writeAsBytes([137, 80, 78, 71, 13, 10, 26, 10]);
    previousPicker = ImagePickerPlatform.instance;
    picker = _Picker(file.path);
    ImagePickerPlatform.instance = picker;
    extraction = _Engine();
    bills = [bill(50, 'electricity')];
    engineCalls = 0;
    when(() => extraction.extractFromImage(any(), any(),
        billGuard: any(named: 'billGuard'))).thenAnswer((_) async {
      engineCalls++;
      return bills;
    });
  });
  tearDown(() async {
    ImagePickerPlatform.instance = previousPicker;
    await db.close();
    await directory.delete(recursive: true);
  });

  Future<void> host(WidgetTester t,
      {bool failPostProcessing = false,
      bool failAttachment = false,
      bool useRealCrop = false}) async {
    final attachments = _Attachments();
    when(() => attachments.saveAttachment(
        transactionId: any(named: 'transactionId'),
        sourceFile: any(named: 'sourceFile'),
        index: any(named: 'index'))).thenAnswer((_) async => null);
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo),
      currentLedgerIdProvider.overrideWith((ref) => ledger.id),
      currentLedgerProvider.overrideWith((ref) => Stream.value(ledger)),
      aiExtractionEngineProvider.overrideWithValue(extraction),
      billingImageServiceProvider.overrideWithValue(_Images()),
      if (!useRealCrop) imageCropServiceProvider.overrideWithValue(_Crop()),
      attachmentServiceProvider.overrideWithValue(attachments),
      smartBillingAutoAttachmentProvider.overrideWith((ref) => failAttachment),
      syncServiceProvider.overrideWith((ref) {
        if (failPostProcessing) throw StateError('synthetic post-save error');
        return LocalOnlySyncService();
      }),
    ]);
    await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: beeTheme(),
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Consumer(builder: (ctx, ref, _) {
              context = ctx;
              widgetRef = ref;
              return const Scaffold(body: SizedBox.shrink());
            }))));
    await t.pumpAndSettle();
  }

  Future<void> waitForReview(WidgetTester t) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      if (find
          .byKey(const ValueKey('image-billing-review-save'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }
    expect(find.byKey(const ValueKey('image-billing-review-save')),
        findsOneWidget);
    await t.pump(const Duration(milliseconds: 300));
  }

  Future<void> confirm(WidgetTester t, Future<void> operation) async {
    await t.tap(find.byKey(const ValueKey('image-billing-review-save')));
    await t.runAsync(() => operation);
    await t.pumpAndSettle();
  }

  Future<void> finish(WidgetTester t) async {
    await t.pump(const Duration(seconds: 5));
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox.shrink());
    container.dispose();
  }

  Future<void> start() =>
      ImageBillingHelper.pickImageForBilling(context, widgetRef);
  Future<void> launch(WidgetTester t) async {
    await t.runAsync(() async {
      operation = start();
    });
    await waitForReview(t);
  }

  Future<List<Transaction>?> rows(WidgetTester t) =>
      t.runAsync(() => db.select(db.transactions).get());

  testWidgets('image billing opens the fixed crop editor before recognition',
      (t) async {
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => directory.path);
    addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));
    final source = File(picker.path);
    await t.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
          const Rect.fromLTWH(0, 0, 320, 240), Paint()..color = Colors.white);
      canvas.drawRect(
          const Rect.fromLTWH(40, 30, 200, 120), Paint()..color = Colors.blue);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(320, 240);
      picture.dispose();
      try {
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await source.writeAsBytes(Uint8List.sublistView(png));
      } finally {
        image.dispose();
      }
    });
    await host(t, useRealCrop: true);
    final saveCrop = find.byKey(const ValueKey('attachment-crop-save'));
    Future<void> openCrop() async {
      await t.runAsync(() async {
        operation = start();
      });
      for (var attempt = 0; attempt < 100; attempt++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await t.pump(const Duration(milliseconds: 20));
        if (saveCrop.evaluate().isNotEmpty &&
            t.widget<IconButton>(saveCrop).onPressed != null) {
          return;
        }
      }
      fail('Image billing crop editor did not become ready');
    }

    await openCrop();
    expect(find.byType(AttachmentCropPage), findsOneWidget);
    expect(t.widget<Crop>(find.byType(Crop)).interactive, isFalse);
    expect(engineCalls, 0);
    await t.tap(find.byKey(const ValueKey('attachment-crop-cancel')));
    await t.runAsync(() => operation);
    await t.pumpAndSettle();
    expect(engineCalls, 0);
    expect(await rows(t), isEmpty);

    await openCrop();
    await t.drag(find.byType(DotControl).last, const Offset(-40, -30));
    await t.pump();
    await t.tap(saveCrop);
    await waitForReview(t);
    final inputs = verify(() => extraction.extractFromImage(captureAny(), any(),
        billGuard: any(named: 'billGuard'))).captured;
    final input = inputs.single as File;
    expect(input.path, isNot(source.path));
    final png = input.readAsBytesSync();
    final dimensions = ByteData.sublistView(png, 16, 24);
    expect(dimensions.getUint32(0), lessThan(320));
    expect(dimensions.getUint32(4), lessThan(240));
    expect(await rows(t), isEmpty);
    await confirm(t, operation);
    expect(await rows(t), hasLength(1));
    await finish(t);
  });

  testWidgets(
      'no financial write before review; unrelated existing bill is unselected',
      (t) async {
    final old = bill(10, 'old lunch');
    await repo.addTransaction(
        ledgerId: ledger.id,
        type: 'expense',
        amount: 10,
        happenedAt: old.time!,
        note: old.note,
        currencyCode: 'CNY');
    bills = [old, bill(50, 'electricity')];
    await host(t);
    await launch(t);
    expect(await rows(t), hasLength(1));
    expect(
        t
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('image-billing-review-0')))
            .value,
        isFalse);
    expect(
        t
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('image-billing-review-1')))
            .value,
        isTrue);
    await confirm(t, operation);
    expect(await rows(t), hasLength(2));
    expect(
        (await rows(t))!.where((row) => row.note == 'old lunch'), hasLength(1));
    await finish(t);
  });

  testWidgets(
      'partial outcome shows failures and retry saves only the unfinished item',
      (t) async {
    bills = [bill(50, 'electricity'), bill(5, 'bus')];
    await db.customStatement(
        '''CREATE TEMP TRIGGER reject_bus BEFORE INSERT ON transactions
      WHEN NEW.note = 'bus' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END''');
    await host(t);
    await launch(t);
    await confirm(t, operation);
    final toast = t.widget<BeeToast>(find.byType(BeeToast));
    expect(toast.tone, BeeTone.warning);
    expect(toast.message, contains('已新增 1 笔'));
    expect(toast.message, contains('未保存 1 笔'));
    expect(await rows(t), hasLength(1));
    await t.runAsync(() => db.customStatement('DROP TRIGGER reject_bus'));
    await launch(t);
    await confirm(t, operation);
    expect(await rows(t), hasLength(2));
    expect(engineCalls, 1);
    await finish(t);
  });

  testWidgets(
      'post-save errors show saved status and cannot duplicate on retry',
      (t) async {
    await host(t, failPostProcessing: true);
    await launch(t);
    await confirm(t, operation);
    final toast = t.widget<BeeToast>(find.byType(BeeToast));
    expect(toast.tone, BeeTone.warning);
    expect(toast.message, contains('账单已保存'));
    expect(toast.message, isNot(contains('识别失败')));
    await t.runAsync(start);
    await t.pumpAndSettle();
    expect(await rows(t), hasLength(1));
    expect(
        t.widget<BeeToast>(find.byType(BeeToast)).message, contains('已记过 1 笔'));
    expect(engineCalls, 1);
    await finish(t);
  });

  testWidgets('attachment null is visible while payment remains saved',
      (t) async {
    await host(t, failAttachment: true);
    await launch(t);
    await confirm(t, operation);
    final toast = t.widget<BeeToast>(find.byType(BeeToast));
    expect(toast.tone, BeeTone.warning);
    expect(toast.message, contains('附件未保存'));
    expect(await rows(t), hasLength(1));
    await finish(t);
  });

  testWidgets('entry reentrancy is rejected and cancelled review saves nothing',
      (t) async {
    await host(t);
    await launch(t);
    await t.runAsync(start);
    expect(picker.calls, 1);
    await t.tap(find.text('取消'));
    await t.runAsync(() => operation);
    await t.pumpAndSettle();
    expect(await rows(t), isEmpty);
    await finish(t);
  });

  testWidgets(
      'review permits explicitly selecting two identical independent payments',
      (t) async {
    bills = [bill(50, 'electricity'), bill(50, 'electricity')];
    await host(t);
    await launch(t);
    final second = find.byKey(const ValueKey('image-billing-review-1'));
    expect(t.widget<CheckboxListTile>(second).value, isFalse);
    await t.tap(second);
    await t.pump();
    await confirm(t, operation);
    expect(await rows(t), hasLength(2));
    await finish(t);
  });
}
