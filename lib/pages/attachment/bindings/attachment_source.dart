import 'dart:io';

import 'package:beecount_business_ui/beecount_business_ui.dart';
import 'package:beecount_ui/beecount_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/attachment_service.dart';
import '../../../services/image_crop_service.dart';

enum _AttachmentSource { camera, gallery }

/// Shared App binding: the UI package never requests permissions or files.
Future<List<File>> pickAttachmentFiles(BuildContext context, WidgetRef ref,
    {required int remaining}) async {
  if (remaining <= 0) return [];
  final l10n = AppLocalizations.of(context);
  final source = await showBeeSheet<_AttachmentSource>(context,
      title: l10n.attachmentAdd,
      child: BeeAttachmentSources(
          cameraLabel: l10n.attachmentTakePhoto,
          galleryLabel: l10n.attachmentChooseFromGallery,
          onCamera: () => Navigator.pop(context, _AttachmentSource.camera),
          onGallery: () => Navigator.pop(context, _AttachmentSource.gallery)));
  if (source == null || !context.mounted) return [];
  final service = ref.read(attachmentServiceProvider);
  final List<File> files;
  if (source == _AttachmentSource.gallery) {
    files = await service.pickFromGallery(maxCount: remaining);
  } else {
    final file = await service.takePhoto();
    files = file == null ? [] : [file];
  }
  if (!context.mounted) return [];
  return cropPickedAttachmentFiles(context, ref, files);
}

/// Batches retain their multi-select workflow and can be cropped individually
/// in the preview. Single photos open the cropper immediately.
Future<List<File>> cropPickedAttachmentFiles(
    BuildContext context, WidgetRef ref, List<File> files) async {
  if (!context.mounted || files.isEmpty) return [];
  if (files.length != 1) return List.unmodifiable(files);
  final l = AppLocalizations.of(context);
  try {
    final cropped =
        await ref.read(imageCropServiceProvider).crop(context, files.single);
    return cropped == null ? [] : [cropped];
  } catch (_) {
    if (context.mounted) {
      showBeeToast(context, l.imageCropFailed, tone: BeeTone.error);
    }
    return [];
  }
}
