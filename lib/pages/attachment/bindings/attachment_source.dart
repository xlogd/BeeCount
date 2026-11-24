import 'dart:io';

import 'package:beecount_business_ui/beecount_business_ui.dart';
import 'package:beecount_ui/beecount_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/attachment_service.dart';
import '../../../services/document_scan_service.dart';
import '../../../services/document_flatten_service.dart';
import '../../../services/image_crop_service.dart';
import '../../../services/system/logger_service.dart';
import '../../../utils/invoice_file.dart';
import '../document_flatten_page.dart';

enum _AttachmentSource { camera, gallery, scan, invoice }

/// Shared App binding: the UI package never requests permissions or files.
Future<List<File>> pickAttachmentFiles(BuildContext context, WidgetRef ref,
    {required int remaining}) async {
  if (remaining <= 0) return [];
  final l10n = AppLocalizations.of(context);
  final canScan = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  final source = await showBeeSheet<_AttachmentSource>(context,
      title: l10n.attachmentAdd,
      child: BeeAttachmentSources(
          cameraLabel: l10n.attachmentTakePhoto,
          galleryLabel: l10n.attachmentChooseFromGallery,
          scanLabel: canScan ? l10n.attachmentScanDocument : null,
          invoiceLabel: l10n.attachmentAddInvoice,
          onInvoice: () => Navigator.pop(context, _AttachmentSource.invoice),
          onCamera: () => Navigator.pop(context, _AttachmentSource.camera),
          onGallery: () => Navigator.pop(context, _AttachmentSource.gallery),
          onScan: canScan
              ? () => Navigator.pop(context, _AttachmentSource.scan)
              : null));
  if (source == null || !context.mounted) return [];
  if (source == _AttachmentSource.scan) {
    return scanAttachmentFiles(context, ref, remaining: remaining);
  }
  if (source == _AttachmentSource.invoice) return pickInvoice(context);
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

Future<List<File>> pickInvoice(BuildContext context) async {
  final l = AppLocalizations.of(context);
  try {
    final result = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (result == null || !context.mounted) return [];
    final path = result.files.single.path;
    if (path == null) throw const FormatException('Missing invoice path');
    final file = File(path);
    await validateInvoiceFile(file);
    return [file];
  } catch (_) {
    if (context.mounted) {
      showBeeToast(context, l.attachmentInvoiceInvalid, tone: BeeTone.error);
    }
    return [];
  }
}

Future<void> openInvoice(BuildContext context, File file) async {
  final l = AppLocalizations.of(context);
  try {
    final result = await OpenFilex.open(file.path,
        type: 'application/pdf', uti: 'com.adobe.pdf');
    if (result.type == ResultType.done) return;
  } catch (_) {
    // The host may have no PDF viewer available.
  }
  if (context.mounted) {
    showBeeToast(context, l.attachmentInvoiceOpenFailed, tone: BeeTone.error);
  }
}

Future<List<File>> scanAttachmentFiles(BuildContext context, WidgetRef ref,
    {required int remaining}) async {
  final l = AppLocalizations.of(context);
  try {
    final files = await ref.read(documentScanServiceProvider).scan(
        remaining: remaining,
        onPageLimit: (skipped) {
          if (context.mounted) {
            showBeeToast(context, l.attachmentScanPageLimit(skipped),
                tone: BeeTone.warning);
          }
        });
    if (files.isEmpty) return files;
    final selected = !context.mounted
        ? null
        : supportsDocumentFlatten
            ? await reviewDocumentPages(
                context, files, ref.read(documentFlattenServiceProvider))
            : files;
    final keep = selected?.map((file) => file.path).toSet() ?? {};
    for (final file in files) {
      if (!keep.contains(file.path)) await discardFlattenedPreview(file);
    }
    return selected ?? [];
  } catch (error) {
    // Errors can include private file paths. Record the stage without those paths.
    logger.warning(
        'DocumentScan', 'Scan or import failed: ${error.runtimeType}');
    if (context.mounted) {
      showBeeToast(context, l.attachmentScanFailed, tone: BeeTone.error);
    }
    return [];
  }
}

void showAttachmentSaveWarning(BuildContext context, int saved, int total,
    {bool retryDraft = false}) {
  if (saved == total) return;
  final l = AppLocalizations.of(context);
  showBeeToast(
      context,
      retryDraft
          ? l.attachmentSaveRetry(saved, total)
          : l.attachmentSaveIncomplete(saved, total),
      tone: BeeTone.warning);
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
