import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_cropper/image_cropper.dart';

import '../l10n/app_localizations.dart';

enum ImageCropPurpose { attachment, avatar, icon, recognition }

final imageCropServiceProvider =
    Provider<ImageCropService>((ref) => ImageCropService());

/// Produces a new temporary image. Cancelling never changes the source file.
class ImageCropService {
  ImageCropService({ImageCropper? cropper})
      : _cropper = cropper ?? ImageCropper();
  final ImageCropper _cropper;

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
    final result = await _cropper.cropImage(
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
