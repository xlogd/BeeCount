import 'dart:io';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/services/image_crop_service.dart';
import 'package:beecount/services/ui/avatar_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Picker extends Mock implements ImagePicker {}

class _Crop extends ImageCropService {
  File? result;
  bool fail = false;
  ImageCropPurpose? purpose;
  @override
  Future<File?> crop(BuildContext context, File source,
      {ImageCropPurpose purpose = ImageCropPurpose.attachment,
      Color? primaryColor}) async {
    this.purpose = purpose;
    if (fail) throw StateError('Synthetic crop failure');
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(ImageSource.gallery);
  late Directory directory;
  late File old, selected, cropped;
  late _Picker picker;
  late _Crop crop;
  late BuildContext context;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('beecount-avatar-crop-');
    await Directory('${directory.path}/avatars').create();
    old = await File('${directory.path}/avatars/avatar_1.png')
        .writeAsBytes([1, 2, 3]);
    selected =
        await File('${directory.path}/selected.png').writeAsBytes([4, 5, 6]);
    cropped =
        await File('${directory.path}/cropped.png').writeAsBytes([7, 8, 9]);
    SharedPreferences.setMockInitialValues(
        {'user_avatar_path': 'avatars/avatar_1.png'});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => directory.path);
    picker = _Picker();
    crop = _Crop();
    when(() => picker.pickImage(source: any(named: 'source')))
        .thenAnswer((_) async => XFile(selected.path));
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    await directory.delete(recursive: true);
  });
  Future<void> host(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(builder: (value) {
          context = value;
          return const SizedBox.shrink();
        })));
    await tester.pumpAndSettle();
  }

  testWidgets('cancel avatar crop preserves the current image and preference',
      (tester) async {
    await host(tester);
    expect(
        await tester.runAsync(() => AvatarService.pickAndSaveAvatar(context,
            picker: picker, cropper: crop)),
        isNull);
    expect(await tester.runAsync(() => old.readAsBytes()), [1, 2, 3]);
    expect(
        (await SharedPreferences.getInstance()).getString('user_avatar_path'),
        'avatars/avatar_1.png');
  });
  for (final camera in [false, true]) {
    testWidgets(
        '${camera ? 'camera' : 'gallery'} saves crop output before removing the old avatar',
        (tester) async {
      await host(tester);
      crop.result = cropped;
      final result = await tester.runAsync(() => camera
          ? AvatarService.takePhotoAndSaveAvatar(context,
              picker: picker, cropper: crop)
          : AvatarService.pickAndSaveAvatar(context,
              picker: picker, cropper: crop));
      expect(
          await tester.runAsync(() => File(result!).readAsBytes()), [7, 8, 9]);
      expect(await tester.runAsync(() => selected.readAsBytes()), [4, 5, 6]);
      expect(await tester.runAsync(() => old.exists()), isFalse);
      expect(crop.purpose, ImageCropPurpose.avatar);
      expect(
          await tester.runAsync(() => AvatarService.getAvatarPath()), result);
      verify(() => picker.pickImage(
          source: camera ? ImageSource.camera : ImageSource.gallery)).called(1);
    });
  }
  testWidgets('crop failure preserves the old avatar', (tester) async {
    await host(tester);
    crop.fail = true;
    await tester.runAsync(() async {
      await expectLater(
          AvatarService.pickAndSaveAvatar(context,
              picker: picker, cropper: crop),
          throwsStateError);
    });
    expect(await tester.runAsync(() => old.readAsBytes()), [1, 2, 3]);
    expect(
        (await SharedPreferences.getInstance()).getString('user_avatar_path'),
        'avatars/avatar_1.png');
  });
  test(
      'new avatar storage failure does not delete the old file or change preferences',
      () async {
    final blocked = await File('${directory.path}/blocked')
        .writeAsString('not a directory');
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => ++calls == 1 ? directory.path : blocked.path);
    await expectLater(
        AvatarService.saveAvatarFromBytes(Uint8List.fromList([7, 8, 9]),
            extension: '.png'),
        throwsA(isA<FileSystemException>()));
    expect(await old.readAsBytes(), [1, 2, 3]);
    expect(
        (await SharedPreferences.getInstance()).getString('user_avatar_path'),
        'avatars/avatar_1.png');
  });
}
