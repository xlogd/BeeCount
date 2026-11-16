import 'dart:io';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/services/image_crop_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:mocktail/mocktail.dart';

class _Cropper extends Mock implements ImageCropper {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(ImageCompressFormat.png);
  registerFallbackValue(const CropAspectRatio(ratioX: 1, ratioY: 1));
  registerFallbackValue(<PlatformUiSettings>[]);
  late Directory directory;
  late File source, output;
  late _Cropper cropper;
  late ImageCropService service;
  late BuildContext context;
  Map<Symbol, dynamic>? arguments;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('beecount-crop-');
    source =
        await File('${directory.path}/source.png').writeAsBytes([1, 2, 3, 4]);
    output =
        await File('${directory.path}/cropped.png').writeAsBytes([5, 6, 7]);
    cropper = _Cropper();
    service = ImageCropService(cropper: cropper);
    when(() => cropper.cropImage(
          sourcePath: any(named: 'sourcePath'),
          maxWidth: any(named: 'maxWidth'),
          maxHeight: any(named: 'maxHeight'),
          aspectRatio: any(named: 'aspectRatio'),
          compressFormat: any(named: 'compressFormat'),
          compressQuality: any(named: 'compressQuality'),
          uiSettings: any(named: 'uiSettings'),
        )).thenAnswer((call) async {
      arguments = call.namedArguments;
      return CroppedFile(output.path);
    });
  });
  tearDown(() async => directory.delete(recursive: true));
  Future<void> host(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (value) {
        context = value;
        return const SizedBox.shrink();
      }),
    ));
    await tester.pumpAndSettle();
  }

  for (final purpose in ImageCropPurpose.values) {
    testWidgets(
        'crop purpose $purpose sets native shape, quality and dimensions',
        (tester) async {
      await host(tester);
      final result = await tester
          .runAsync(() => service.crop(context, source, purpose: purpose));
      expect(result!.path, output.path);
      expect(await tester.runAsync(() => source.readAsBytes()), [1, 2, 3, 4]);
      final square = purpose == ImageCropPurpose.avatar ||
          purpose == ImageCropPurpose.icon;
      final android = (arguments![#uiSettings] as List<PlatformUiSettings>)
          .whereType<AndroidUiSettings>()
          .single;
      final ios = (arguments![#uiSettings] as List<PlatformUiSettings>)
          .whereType<IOSUiSettings>()
          .single;
      expect(android.lockAspectRatio, square);
      expect(ios.aspectRatioLockEnabled, square);
      expect(arguments![#compressFormat], ImageCompressFormat.png);
      expect(arguments![#compressQuality], 100);
      expect(
          arguments![#maxWidth],
          purpose == ImageCropPurpose.icon
              ? 512
              : purpose == ImageCropPurpose.avatar
                  ? 1024
                  : null);
      expect(
          android.cropStyle,
          purpose == ImageCropPurpose.avatar
              ? CropStyle.circle
              : CropStyle.rectangle);
    });
  }
  testWidgets('cancel keeps the original and returns no replacement',
      (tester) async {
    await host(tester);
    when(() => cropper.cropImage(
        sourcePath: any(named: 'sourcePath'),
        maxWidth: any(named: 'maxWidth'),
        maxHeight: any(named: 'maxHeight'),
        aspectRatio: any(named: 'aspectRatio'),
        compressFormat: any(named: 'compressFormat'),
        compressQuality: any(named: 'compressQuality'),
        uiSettings: any(named: 'uiSettings'))).thenAnswer((_) async => null);
    expect(await tester.runAsync(() => service.crop(context, source)), isNull);
    expect(await tester.runAsync(() => source.readAsBytes()), [1, 2, 3, 4]);
  });
  testWidgets('an empty crop output is rejected without deleting the source',
      (tester) async {
    await host(tester);
    await tester.runAsync(() => output.writeAsBytes([]));
    await tester.runAsync(() async {
      await expectLater(service.crop(context, source), throwsFormatException);
    });
    expect(await tester.runAsync(() => source.exists()), isTrue);
  });
  testWidgets('platform failure preserves the source image', (tester) async {
    await host(tester);
    when(() => cropper.cropImage(
            sourcePath: any(named: 'sourcePath'),
            maxWidth: any(named: 'maxWidth'),
            maxHeight: any(named: 'maxHeight'),
            aspectRatio: any(named: 'aspectRatio'),
            compressFormat: any(named: 'compressFormat'),
            compressQuality: any(named: 'compressQuality'),
            uiSettings: any(named: 'uiSettings')))
        .thenThrow(PlatformException(code: 'crop_failed'));
    await tester.runAsync(() async {
      await expectLater(
          service.crop(context, source), throwsA(isA<PlatformException>()));
    });
    expect(await tester.runAsync(() => source.readAsBytes()), [1, 2, 3, 4]);
  });
}
