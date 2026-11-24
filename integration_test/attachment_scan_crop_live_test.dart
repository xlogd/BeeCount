// Run only on an independently packaged QA emulator.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/pages/attachment/attachment_crop_page.dart';
import 'package:beecount/services/document_scan_service.dart';
import 'package:beecount/services/image_crop_service.dart';
import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

const runId = String.fromEnvironment('QA_RUN_ID');
const qaPackage = 'com.tntlikely.beecount.qa.dev.debug';

Future<Uint8List> syntheticImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
      const Rect.fromLTWH(0, 0, 500, 700), Paint()..color = Colors.white);
  canvas.drawRect(
      const Rect.fromLTWH(80, 100, 340, 500), Paint()..color = Colors.teal);
  final image = await recorder.endRecording().toImage(500, 700);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.shouldPropagateDevicePointerEvents = true;
  final cases = <Map<String, Object?>>[];
  binding.reportData = {'run_id': runId, 'cases': cases};

  testWidgets('attachment crop frame moves and resizes on a real emulator',
      (tester) async {
    expect((await PackageInfo.fromPlatform()).packageName, qaPackage);
    expect(runId.startsWith('beecount-scan-crop-qa-'), isTrue);
    final source = File(
        '${(await getTemporaryDirectory()).path}/qa-synthetic-receipt.png');
    final original = await syntheticImage();
    await source.writeAsBytes(original, flush: true);
    File? result;
    await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Builder(builder: (context) {
          return FilledButton(
              onPressed: () async =>
                  result = await ImageCropService().crop(context, source),
              child: const Text('QA crop'));
        }))));
    await tester.tap(find.text('QA crop'));
    for (var i = 0;
        i < 100 && find.byType(AttachmentCropPage).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    expect(find.byType(AttachmentCropPage), findsOneWidget);
    for (var i = 0;
        i < 100 &&
            tester
                    .widget<IconButton>(
                        find.byKey(const ValueKey('attachment-crop-save')))
                    .onPressed ==
                null;
        i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    expect(tester.widget<Crop>(find.byType(Crop)).interactive, isFalse);
    expect(find.byType(DotControl), findsNWidgets(4));
    debugPrint('QA_CROP_READY');
    if (const bool.fromEnvironment('QA_CAPTURE_CROP')) {
      await Future<void>.delayed(const Duration(seconds: 45));
    }
    await tester.drag(find.byType(DotControl).last, const Offset(-70, -100));
    await tester.pump();
    expect(
        tester
            .widget<IconButton>(
                find.byKey(const ValueKey('attachment-crop-undo')))
            .onPressed,
        isNotNull);
    await tester.tap(find.byKey(const ValueKey('attachment-crop-save')));
    for (var i = 0; i < 100 && result == null; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(result, isNotNull);
    final output = await result!.readAsBytes();
    final header = ByteData.sublistView(output, 16, 24);
    expect(header.getUint32(0), lessThan(500));
    expect(header.getUint32(4), lessThan(700));
    expect(await source.readAsBytes(), original);
    cases.add({
      'name': 'crop',
      'status': 'PASS',
      'width': header.getUint32(0),
      'height': header.getUint32(4),
    });
    debugPrint('QA_CROP_PASS');
  });

  testWidgets('native document scanner opens and cancels cleanly',
      (tester) async {
    List<File>? scanned;
    Object? failure;
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Builder(builder: (context) {
      return FilledButton(
          onPressed: () async {
            try {
              scanned = await DocumentScanService().scan(remaining: 2);
            } catch (error) {
              failure = error;
            }
          },
          child: const Text('QA scan'));
    }))));
    await tester.tap(find.text('QA scan'));
    debugPrint('QA_SCAN_REQUESTED');
    for (var i = 0; i < 120 && scanned == null && failure == null; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(failure, isNull);
    expect(scanned, isEmpty);
    cases.add({'name': 'scanner-cancel', 'status': 'PASS'});
    debugPrint('QA_SCAN_CANCEL_PASS');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
