import 'dart:io';
import 'dart:ui' as ui;

import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/services/image_crop_service.dart';
import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Uint8List> _testImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
      const Rect.fromLTWH(0, 0, 100, 120), Paint()..color = Colors.red);
  canvas.drawRect(
      const Rect.fromLTWH(100, 0, 100, 120), Paint()..color = Colors.blue);
  final image = await recorder.endRecording().toImage(200, 120);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<void> _waitReady(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 40));
    final save = find.byKey(const ValueKey('attachment-crop-save'));
    if (save.evaluate().isNotEmpty &&
        tester.widget<IconButton>(save).onPressed != null) {
      return;
    }
  }
  fail('Crop editor did not become ready');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File source;
  late Uint8List original;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('beecount-crop-frame-');
    original = await _testImage();
    source = File('${directory.path}/receipt.png')..writeAsBytesSync(original);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => directory.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    await directory.delete(recursive: true);
  });

  Future<void> host(WidgetTester tester,
      {required void Function(File?) onResult}) async {
    await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Builder(builder: (context) {
          return FilledButton(
              onPressed: () async =>
                  onResult(await ImageCropService().crop(context, source)),
              child: const Text('Open crop'));
        }))));
    await tester.pump();
    await tester.tap(find.text('Open crop'));
    await _waitReady(tester);
  }

  testWidgets('frame moves and resizes over a fixed image; save writes crop',
      (tester) async {
    File? result;
    await host(tester, onResult: (file) => result = file);
    final crop = tester.widget<Crop>(find.byType(Crop));
    expect(crop.interactive, isFalse);
    expect(crop.fixCropRect, isFalse);
    expect(crop.initialRectBuilder, isNotNull);

    final frame = find.byType(DotControl);
    expect(frame, findsNWidgets(4));
    await tester.drag(frame.last, const Offset(-36, -22));
    await tester.pump();
    expect(
        tester
            .widget<IconButton>(
                find.byKey(const ValueKey('attachment-crop-undo')))
            .onPressed,
        isNotNull);
    await tester.tap(find.byKey(const ValueKey('attachment-crop-save')));
    for (var i = 0; i < 100 && result == null; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(result, isNotNull);
    expect(result!.path, endsWith('.png'));
    final bytes = result!.readAsBytesSync();
    expect(bytes, isNotEmpty);
    final header = ByteData.sublistView(bytes, 16, 24);
    expect(header.getUint32(0), lessThan(200));
    expect(header.getUint32(4), lessThan(120));
    expect(source.readAsBytesSync(), original);
  });

  testWidgets('cancel leaves the original image unchanged', (tester) async {
    File? result;
    var returned = false;
    await host(tester, onResult: (file) {
      result = file;
      returned = true;
    });
    await tester.tap(find.byKey(const ValueKey('attachment-crop-cancel')));
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(result, isNull);
    expect(source.readAsBytesSync(), original);
  });
}
