import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../services/custom_icon_service.dart';
import '../../../../services/image_crop_service.dart';

final categoryIconServiceProvider =
    Provider<CustomIconService>((ref) => CustomIconService());
final categoryIconPickerProvider = Provider<CategoryIconPicker>(
    (ref) => CategoryIconPicker(cropper: ref.read(imageCropServiceProvider)));

/// Returns a temporary crop only. Picking/cancelling never writes category data
/// or deletes a saved icon; promotion happens in the explicit save operation.
class CategoryIconPicker {
  CategoryIconPicker({ImageCropService? cropper})
      : _cropper = cropper ?? ImageCropService();
  final ImageCropService _cropper;
  Future<File?> pick(BuildContext context, Color primary) async {
    final image = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (image == null || !context.mounted) return null;
    return _cropper.crop(context, File(image.path),
        purpose: ImageCropPurpose.icon, primaryColor: primary);
  }
}
