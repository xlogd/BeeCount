import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../image_crop_service.dart';
import '../system/logger_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';

/// 头像管理服务
class AvatarService {
  static const String _avatarPathKey = 'user_avatar_path';
  // 服务端的 avatar_version —— sync 时拿来和新拉到的 version 对比，相同就跳过下载。
  static const String _avatarRemoteVersionKey = 'user_avatar_remote_version';

  /// 获取用户头像路径
  ///
  /// 注意：存储的是相对路径，读取时动态拼接 Documents 目录
  /// 这样即使 iOS 应用更新后 UUID 变化，头像也不会丢失
  static Future<String?> getAvatarPath() async {
    final prefs = await SharedPreferences.getInstance();
    final relativePath = prefs.getString(_avatarPathKey);
    if (relativePath == null) return null;

    // 兼容旧版本存储的绝对路径
    if (relativePath.startsWith('/')) {
      // 尝试从绝对路径中提取相对路径并迁移
      final match =
          RegExp(r'avatars/avatar_\d+\.\w+$').firstMatch(relativePath);
      if (match != null) {
        final extracted = match.group(0)!;
        // 检查文件是否在新位置存在
        final appDir = await getApplicationDocumentsDirectory();
        final newPath = p.normalize(p.join(appDir.path, extracted));
        if (await File(newPath).exists()) {
          // 迁移到相对路径
          await prefs.setString(_avatarPathKey, extracted);
          return newPath;
        }
      }
      // 旧路径文件不存在，清除设置
      await prefs.remove(_avatarPathKey);
      return null;
    }

    // 拼接完整路径
    final appDir = await getApplicationDocumentsDirectory();
    final fullPath = p.normalize(p.join(appDir.path, relativePath));

    // 验证文件存在
    if (!await File(fullPath).exists()) {
      await prefs.remove(_avatarPathKey);
      return null;
    }

    return fullPath;
  }

  /// Album/camera selections are committed only after crop confirmation.
  static Future<String?> pickAndSaveAvatar(BuildContext context,
          {ImagePicker? picker, ImageCropService? cropper}) =>
      _pickCropAndSave(context, ImageSource.gallery,
          picker: picker, cropper: cropper);

  static Future<String?> takePhotoAndSaveAvatar(BuildContext context,
          {ImagePicker? picker, ImageCropService? cropper}) =>
      _pickCropAndSave(context, ImageSource.camera,
          picker: picker, cropper: cropper);

  static Future<String?> _pickCropAndSave(
      BuildContext context, ImageSource source,
      {ImagePicker? picker, ImageCropService? cropper}) async {
    final selected = await (picker ?? ImagePicker()).pickImage(source: source);
    if (selected == null || !context.mounted) return null;
    final cropped = await (cropper ?? ImageCropService())
        .crop(context, File(selected.path), purpose: ImageCropPurpose.avatar);
    if (cropped == null || !context.mounted) return null;
    return saveAvatarFromBytes(await cropped.readAsBytes(),
        extension: p.extension(cropped.path));
  }

  /// Remote downloads use the same safe commit without opening a crop UI.
  static Future<String?> saveAvatarFromBytes(Uint8List bytes,
      {String extension = '.jpg'}) async {
    if (bytes.isEmpty) return null;
    final oldPath = await getAvatarPath();
    final appDir = await getApplicationDocumentsDirectory();
    final avatarDir = Directory(p.join(appDir.path, 'avatars'));
    await avatarDir.create(recursive: true);
    var ext = extension.startsWith('.')
        ? extension.toLowerCase()
        : '.${extension.toLowerCase()}';
    if (!RegExp(r'^\.[a-z0-9]+$').hasMatch(ext)) ext = '.jpg';
    final fileName = 'avatar_${DateTime.now().microsecondsSinceEpoch}$ext';
    final relativePath = 'avatars/$fileName';
    final target = File(p.join(avatarDir.path, fileName));
    try {
      await target.writeAsBytes(bytes, flush: true);
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_avatarPathKey, relativePath)) {
        throw StateError('Avatar preference was not saved');
      }
    } catch (_) {
      try {
        if (await target.exists()) await target.delete();
      } catch (_) {}
      rethrow;
    }
    if (oldPath != null && oldPath != target.path) {
      try {
        final old = File(oldPath);
        if (await old.exists()) await old.delete();
      } catch (error) {
        logger.warning(
            'AvatarService', 'Deferred previous avatar cleanup: $error');
      }
    }
    return target.path;
  }

  /// 取上一次同步下来的远端头像版本（没同步过返回 null 或 0）。
  static Future<int> getStoredRemoteVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_avatarRemoteVersionKey) ?? 0;
  }

  /// 更新本地缓存的远端头像版本。
  static Future<void> setStoredRemoteVersion(int version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_avatarRemoteVersionKey, version);
  }

  /// 清掉本地缓存的远端版本号（登出时用，避免换账号后复用旧版本号跳过下载）。
  static Future<void> clearStoredRemoteVersion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_avatarRemoteVersionKey);
  }

  /// 删除头像
  static Future<void> deleteAvatar() async {
    await _deleteOldAvatar();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_avatarPathKey);
    await prefs.remove(_avatarRemoteVersionKey);
  }

  /// 删除旧头像文件（内部方法）
  static Future<void> _deleteOldAvatar() async {
    final avatarPath = await getAvatarPath();
    if (avatarPath != null) {
      final file = File(avatarPath);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }
}
