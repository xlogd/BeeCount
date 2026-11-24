import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../l10n/app_localizations.dart';
import '../pages/attachment/attachment_crop_page.dart';

enum ImageCropPurpose { attachment, avatar, icon, recognition }

final imageCropServiceProvider =
    Provider<ImageCropService>((ref) => ImageCropService());

/// Produces a new temporary image. Cancelling never changes the source file.
class ImageCropService {
  ImageCropService({ImageCropper? cropper}) : _cropper = cropper;
  final ImageCropper? _cropper;

  Future<File?> crop(
    BuildContext context,
    File source, {
    ImageCropPurpose purpose = ImageCropPurpose.attachment,
    Color? primaryColor,
  }) async {
    final l = AppLocalizations.of(context);
    final primary = primaryColor ?? Theme.of(context).colorScheme.primary;
    final colors = Theme.of(context).colorScheme;
    if (!await source.exists()) {
      throw FileSystemException('Image does not exist', source.path);
    }
    if (!context.mounted) return null;
    final square =
        purpose == ImageCropPurpose.avatar || purpose == ImageCropPurpose.icon;
    final title = switch (purpose) {
      ImageCropPurpose.avatar => l.imageCropAvatarTitle,
      ImageCropPurpose.icon => l.categoryCustomIconCrop,
      _ => l.imageCropTitle,
    };
    final maximum = purpose == ImageCropPurpose.icon
        ? 512
        : purpose == ImageCropPurpose.avatar
            ? 1024
            : null;
    final extension = p.extension(source.path).toLowerCase();
    final commonFormat = const {'.jpg', '.jpeg', '.png'}.contains(extension);
    if (_cropper == null &&
        (purpose == ImageCropPurpose.recognition ||
            (purpose == ImageCropPurpose.attachment && commonFormat))) {
      final bytes = commonFormat
          ? await source.readAsBytes()
          // The native decoder can read phone formats such as HEIC. Convert
          // only the working copy so the crop editor can read it.
          : await FlutterImageCompress.compressWithFile(source.path,
              format: CompressFormat.png, minWidth: 4096, minHeight: 4096);
      if (bytes == null || bytes.isEmpty) {
        throw const FormatException('Could not decode image for cropping');
      }
      if (!context.mounted) return null;
      final cropped = await Navigator.of(context).push<Uint8List>(
          MaterialPageRoute(builder: (_) => AttachmentCropPage(image: bytes)));
      if (cropped == null || !context.mounted) return null;
      if (cropped.isEmpty) {
        throw const FormatException('Cropped image is empty');
      }
      final outputExtension =
          cropped.length > 2 && cropped[0] == 0xff && cropped[1] == 0xd8
              ? '.jpg'
              : '.png';
      final directory = await getTemporaryDirectory();
      final file = File(p.join(directory.path,
          'beecount_attachment_crop_${const Uuid().v4()}$outputExtension'));
      await file.writeAsBytes(cropped, flush: true);
      return file;
    }
    final result = await (_cropper ?? ImageCropper()).cropImage(
      sourcePath: source.path,
      aspectRatio: square ? const CropAspectRatio(ratioX: 1, ratioY: 1) : null,
      maxWidth: maximum,
      maxHeight: maximum,
      compressFormat: ImageCompressFormat.png,
      compressQuality: 100,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: title,
          toolbarColor: colors.surface,
          toolbarWidgetColor: colors.onSurface,
          activeControlsWidgetColor: primary,
          cropStyle: purpose == ImageCropPurpose.avatar
              ? CropStyle.circle
              : CropStyle.rectangle,
          initAspectRatio: square
              ? CropAspectRatioPreset.square
              : CropAspectRatioPreset.original,
          lockAspectRatio: square,
          hideBottomControls: false,
        ),
        IOSUiSettings(
          title: title,
          cropStyle: purpose == ImageCropPurpose.avatar
              ? CropStyle.circle
              : CropStyle.rectangle,
          aspectRatioLockEnabled: square,
          resetAspectRatioEnabled: !square,
          aspectRatioPickerButtonHidden: square,
          doneButtonTitle: l.commonSave,
          cancelButtonTitle: l.commonCancel,
        ),
      ],
    );
    if (result == null || !context.mounted) return null;
    final file = File(result.path);
    if (!await file.exists() || await file.length() == 0) {
      throw const FormatException('Cropped image is empty');
    }
    return file;
  }
}
