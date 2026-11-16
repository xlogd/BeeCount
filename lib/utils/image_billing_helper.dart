import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../ai/core/prompt_builder.dart';
import '../ai/providers/ai_provider_config.dart';
import '../ai/providers/ai_provider_manager.dart';
import '../l10n/app_localizations.dart';
import '../pages/shared/feedback/recording_progress_dialog.dart';
import '../providers.dart';
import '../providers/ai_chat_providers.dart';
import '../services/ai/billing_image_service.dart';
import '../services/ai/bookkeeping_feedback.dart';
import '../services/ai/image_billing_source.dart';
import '../services/system/logger_service.dart';
import '../pages/shared/feedback/image_billing_review.dart';
import '../services/attachment_service.dart';
import '../services/image_crop_service.dart';
import '../services/billing/post_processor.dart';
import '../services/data/tag_seed_service.dart';
import 'package:beecount_ui/beecount_ui.dart';

/// 图片记账入口(相册/相机)。瘦身后:UI 流程 + 兜底,业务调 [AiBookkeeper]。
class ImageBillingHelper {
  static bool _processing = false;

  /// 从相册选择图片并自动记账
  static Future<void> pickImageForBilling(
    BuildContext context,
    WidgetRef ref,
  ) =>
      _processImageBilling(context, ref, ImageSource.gallery);

  /// 打开相机拍照并自动记账
  static Future<void> openCameraForBilling(
    BuildContext context,
    WidgetRef ref,
  ) =>
      _processImageBilling(context, ref, ImageSource.camera);

  static Future<void> _processImageBilling(
    BuildContext context,
    WidgetRef ref,
    ImageSource source,
  ) async {
    final l10n = AppLocalizations.of(context);
    if (_processing) {
      showBeeToast(context, l10n.aiBillingBusy, tone: BeeTone.warning);
      return;
    }
    _processing = true;
    BillingImageFiles? images;
    final saving = ValueNotifier(false);
    NavigatorState? progressNavigator;
    DialogRoute<void>? progressRoute;
    void closeProgress() {
      final route = progressRoute;
      if (route != null && route.isActive && progressNavigator!.mounted) {
        progressNavigator!.removeRoute(route);
      }
      progressRoute = null;
    }

    void openProgress(String ledgerName) {
      progressNavigator = Navigator.of(context, rootNavigator: true);
      progressRoute = DialogRoute<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => RecordingProgressDialog(
              saving: saving,
              sourceLabel: source == ImageSource.gallery
                  ? l10n.smartBillingImageBilling
                  : l10n.smartBillingCameraBilling,
              ledgerName: ledgerName));
      progressNavigator!.push(progressRoute!);
    }

    try {
      final imageService = ref.read(billingImageServiceProvider);
      // 1. 选图
      final keepOriginal =
          await ref.read(attachmentKeepOriginalProvider.future);
      final imageFile =
          await imageService.pickImage(source, keepOriginal: true);
      if (imageFile == null) return;
      if (!context.mounted) return;
      final sourceHash = await imageBillingSourceHash(imageFile);
      if (!context.mounted) return;
      final cropped = await ref
          .read(imageCropServiceProvider)
          .crop(context, imageFile, purpose: ImageCropPurpose.recognition)
          .catchError((Object error) {
        if (context.mounted) {
          showBeeToast(context, l10n.imageCropFailed, tone: BeeTone.error);
        }
        return null;
      });
      if (cropped == null || !context.mounted) return;

      // 3. AI vision 兜底
      if (!await AIProviderManager.isCapabilityConfigured(
          AICapabilityType.vision)) {
        if (!context.mounted) return;
        showBeeToast(context, l10n.aiNotConfiguredHint, tone: BeeTone.warning);
        return;
      }

      // 4. 当前账本
      final currentLedger = await ref.read(currentLedgerProvider.future);
      if (currentLedger == null) {
        if (!context.mounted) return;
        showBeeToast(context, l10n.aiOcrNoLedger, tone: BeeTone.warning);
        return;
      }

      if (!context.mounted) return;
      openProgress(currentLedger.name);

      // 5. 委托 AiBookkeeper(自动查 categories/accounts + 多笔保存)
      final autoAddAttachment = ref.read(smartBillingAutoAttachmentProvider);
      final billingTypes = <String>[
        source == ImageSource.gallery
            ? TagSeedService.billingTypeImage
            : TagSeedService.billingTypeCamera,
        TagSeedService.billingTypeAi,
      ];

      final attachmentService = ref.read(attachmentServiceProvider);
      final bookkeeper = ref.read(aiBookkeeperProvider);
      images = await imageService.prepare(cropped, keepOriginal: keepOriginal);
      final result = await bookkeeper.fromImage(
        image: images.recognition,
        ledgerId: currentLedger.id,
        billGuard: PromptBuilder.billGuardForImage,
        billingTypes: billingTypes,
        l10n: l10n,
        sourceFingerprint: sourceHash,
        review: (review) async {
          closeProgress();
          if (!context.mounted) return null;
          final selected = await showImageBillingReview(context, review,
              currency: currentLedger.currency);
          if (selected != null && context.mounted) {
            openProgress(currentLedger.name);
          }
          return selected;
        },
        onSaving: () => saving.value = true,
        // 多笔时每笔都挂同一张原图,方便后续从任意一笔溯源
        onSaved: autoAddAttachment
            ? (txId, _) async {
                final attachment = await attachmentService.saveAttachment(
                  transactionId: txId,
                  sourceFile: images!.attachment,
                  index: 0,
                );
                if (attachment == null) {
                  throw StateError('Billing attachment was not saved');
                }
              }
            : null,
      );

      if (!context.mounted) return;
      closeProgress();
      if (result.cancelled) return;
      if (result.needsReview) {
        showBeeToast(context, l10n.aiImageReviewRequired,
            tone: BeeTone.warning);
        return;
      }

      // 6. 提示用户
      if (!result.success) {
        // failedCount>0:提取到账单但入库失败(真·错误);否则=AI 判定不是账单/没提取到
        showBeeToast(context,
            result.failedCount > 0 ? l10n.aiOcrCheckLog : l10n.aiOcrNoBill,
            tone: BeeTone.warning);
        return;
      }

      var postProcessingFailed = false;
      try {
        if (result.createdCount > 0) {
          await PostProcessor.run(
            ref,
            ledgerId: currentLedger.id,
            tags: true,
            attachments: autoAddAttachment,
          );
        }
      } catch (error, stack) {
        postProcessingFailed = true;
        logger.error('ImageBilling', '账单已保存，后处理待重试', error, stack);
      }
      if (!context.mounted) return;
      final warning = postProcessingFailed ||
          result.failedCount > 0 ||
          result.attachmentFailureCount > 0 ||
          result.unconvertedCurrencies.isNotEmpty;
      showBeeToast(
          context,
          bookkeepingFeedback(l10n, result,
              postProcessingFailed: postProcessingFailed),
          tone: warning ? BeeTone.warning : BeeTone.success);
    } catch (e) {
      if (!context.mounted) return;
      closeProgress();
      showBeeToast(context, l10n.aiOcrFailed(e.toString()),
          tone: BeeTone.error);
    } finally {
      _processing = false;
      closeProgress();
      saving.dispose();
      try {
        await images?.dispose();
      } catch (error) {
        logger.warning('ImageBilling', '识别临时文件清理待重试: $error');
      }
    }
  }
}
