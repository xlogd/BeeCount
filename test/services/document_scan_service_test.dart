import 'dart:io';

import 'package:beecount/services/document_scan_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_doc_scanner/flutter_doc_scanner.dart';
import 'package:flutter_test/flutter_test.dart';

class _Scanner extends FlutterDocScanner {
  ImageScanResult? next;
  int? pageLimit;

  @override
  Future<ImageScanResult?> getScannedDocumentAsImages({
    int page = 4,
    ImageFormat imageFormat = ImageFormat.jpeg,
    double quality = 0.9,
    bool useAutomaticSinglePictureProcessing = false,
  }) async {
    pageLimit = page;
    return next;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const scanChannel = MethodChannel('qa/document_scan');
  late Directory directory;
  late _Scanner scanner;
  late List<String> forwardedUris;
  var nativeCalls = 0;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('beecount-scan-');
    scanner = _Scanner();
    nativeCalls = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        pathChannel, (_) async => directory.path);
    messenger.setMockMethodCallHandler(scanChannel, (call) async {
      nativeCalls++;
      expect(call.method, 'copyImages');
      forwardedUris = (call.arguments['uris'] as List).cast<String>();
      return [
        for (var i = 0; i < forwardedUris.length; i++)
          (File('${directory.path}/native-$i.jpg')
                ..writeAsBytesSync([2 * i + 1, 2 * i + 2]))
              .path,
      ];
    });
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(scanChannel, null);
    await directory.delete(recursive: true);
  });

  test('cancel and zero remaining slots create no files', () async {
    final service = DocumentScanService(
        scanner: scanner, androidChannel: scanChannel, android: true);
    expect(await service.scan(remaining: 0), isEmpty);
    expect(scanner.pageLimit, isNull);
    expect(await service.scan(remaining: 3), isEmpty);
    expect(scanner.pageLimit, 3);
    expect(nativeCalls, 0);
  });

  test('Android file and content URIs reach the native bridge in page order',
      () async {
    const images = [
      'file:///data/user/0/example/cache/mlkit_docscan_ui_client/page%201.jpg',
      'content://scanner/page-2',
    ];
    scanner.next = const ImageScanResult(images: images);
    final service = DocumentScanService(
        scanner: scanner, androidChannel: scanChannel, android: true);
    final files = await service.scan(remaining: 2);
    expect(scanner.pageLimit, 2);
    expect(files.map((file) => file.readAsBytesSync()), [
      [1, 2],
      [3, 4]
    ]);
    expect(nativeCalls, 1);
    expect(forwardedUris, images);
  });

  test('invalid Android result is rejected before copying', () async {
    scanner.next =
        const ImageScanResult(images: ['https://example.com/page.jpg']);
    final service = DocumentScanService(
        scanner: scanner, androidChannel: scanChannel, android: true);
    await expectLater(service.scan(remaining: 1), throwsFormatException);
    expect(nativeCalls, 0);
    scanner.next = const ImageScanResult(images: ['file://remote/image.jpg']);
    await expectLater(service.scan(remaining: 1), throwsFormatException);
    expect(nativeCalls, 0);
  });

  test('iOS retains pages within the limit and cleans plugin output', () async {
    final first = File('${directory.path}/20261119-120000-0.png')
      ..writeAsBytesSync([1, 2]);
    final second = File('${directory.path}/20261119-120000-1.png')
      ..writeAsBytesSync([3, 4]);
    scanner.next = ImageScanResult(images: [first.uri.toString(), second.path]);
    final service = DocumentScanService(scanner: scanner, android: false);
    int? skipped;
    final files = await service.scan(
        remaining: 1, onPageLimit: (count) => skipped = count);
    expect(files.map((file) => file.readAsBytesSync()), [
      [1, 2]
    ]);
    expect(skipped, 1);
    expect(files.every((file) => file.path.contains('beecount_scans')), isTrue);
    expect(first.existsSync(), isFalse);
    expect(second.existsSync(), isFalse);
  });

  test('failed iOS batch removes partial copies', () async {
    final first = File('${directory.path}/20261119-120000-0.png')
      ..writeAsBytesSync([1, 2]);
    scanner.next =
        ImageScanResult(images: [first.path, '${directory.path}/missing.png']);
    final service = DocumentScanService(scanner: scanner, android: false);
    await expectLater(service.scan(remaining: 2), throwsFormatException);
    expect(Directory('${directory.path}/beecount_scans').listSync(), isEmpty);
    expect(first.existsSync(), isFalse);
  });
}
