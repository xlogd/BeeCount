import 'dart:async';
import 'dart:io';

import 'package:beecount/ai/core/ai_extraction_context.dart';
import 'package:beecount/ai/core/ai_extraction_engine.dart';
import 'package:beecount/ai/core/bill_info.dart';
import 'package:beecount/ai/providers/ai_provider_config.dart';
import 'package:beecount/ai/providers/ai_provider_manager.dart';
import 'package:beecount/cloud/sync_service.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/providers.dart';
import 'package:beecount/providers/ai_chat_providers.dart';
import 'package:beecount/services/automation/auto_billing_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Engine extends Mock implements AiExtractionEngine {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(File('synthetic'));
  registerFallbackValue(AiExtractionContext.fallback);
  late Directory directory;
  late File image;
  late BeeDatabase db;
  late LocalRepository repo;
  late _Engine extraction;
  late ProviderContainer container;
  late int ledger;
  var calls = 0;
  Completer<void>? gate;
  late Completer<void> entered;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AIProviderManager.updateProvider(
        AIServiceProviderConfig.zhipuDefault.copyWith(apiKey: 'synthetic'));
    await AIProviderManager.setCapabilityProvider(
        AICapabilityType.vision, 'zhipu_glm');
    directory =
        await Directory.systemTemp.createTemp('beecount-auto-image-test-');
    image =
        await File('${directory.path}/original.png').writeAsBytes([1, 2, 3, 4]);
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    ledger = await repo.createLedger(name: 'Synthetic automatic ledger');
    extraction = _Engine();
    calls = 0;
    gate = null;
    entered = Completer<void>();
    when(() => extraction.extractFromImage(any(), any(),
        billGuard: any(named: 'billGuard'))).thenAnswer((_) async {
      calls++;
      if (!entered.isCompleted) entered.complete();
      if (gate != null) await gate!.future;
      return [
        BillInfo(
            amount: -50,
            type: BillType.expense,
            time: DateTime(2026, 11, 15, 8, 9, 32),
            note: 'electricity',
            currency: 'CNY')
      ];
    });
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo),
      currentLedgerIdProvider.overrideWith((ref) => ledger),
      aiExtractionEngineProvider.overrideWithValue(extraction),
      smartBillingAutoAttachmentProvider.overrideWith((ref) => false),
      syncServiceProvider.overrideWithValue(LocalOnlySyncService()),
    ]);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  test('persisted processed paths are loaded before the first event is checked',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('processed_screenshots', [image.path]);
    final service = AutoBillingService(container);
    expect(await service.processScreenshot(image.path, showNotification: false),
        isNull);
    expect(calls, 0);
    expect(await db.select(db.transactions).get(), isEmpty);
    service.dispose();
  });

  test('concurrent deliveries of one screenshot save exactly once', () async {
    gate = Completer<void>();
    final service = AutoBillingService(container);
    final first =
        service.processScreenshot(image.path, showNotification: false);
    await entered.future;
    final second =
        service.processScreenshot(image.path, showNotification: false);
    gate!.complete();
    final ids = await Future.wait([first, second]);
    expect(ids.first, isNotNull);
    expect(ids.toSet(), hasLength(1));
    expect(calls, 1);
    expect(await db.select(db.transactions).get(), hasLength(1));
    service.dispose();
  });

  test('new cache paths and new service instances cannot replay the same image',
      () async {
    final firstService = AutoBillingService(container);
    final first = await firstService.processScreenshot(image.path,
        showNotification: false);
    final copy = await image.copy('${directory.path}/shared_new_name.jpg');
    final secondService = AutoBillingService(container);
    final second = await secondService.processScreenshot(copy.path,
        showNotification: false);
    expect(second, first);
    expect(calls, 1);
    expect(await db.select(db.transactions).get(), hasLength(1));
    firstService.dispose();
    secondService.dispose();
  });

  test('post-processing failure returns the already saved transaction',
      () async {
    container.dispose();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo),
      currentLedgerIdProvider.overrideWith((ref) => ledger),
      aiExtractionEngineProvider.overrideWithValue(extraction),
      smartBillingAutoAttachmentProvider.overrideWith((ref) => false),
      syncServiceProvider.overrideWith(
          (ref) => throw StateError('synthetic sync startup failure')),
    ]);
    final service = AutoBillingService(container);
    expect(await service.processScreenshot(image.path, showNotification: false),
        isNotNull);
    expect(await db.select(db.transactions).get(), hasLength(1));
    service.dispose();
  });
}
